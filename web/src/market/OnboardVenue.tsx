// Self-serve venue signup at /for-business (E5-T9 / F0.5).
//
// The premise is a salon owner on a phone, in Arabic, over a patchy connection,
// with ten minutes. Everything here follows from that:
//
//   * one question per screen, so nothing needs pinch-zooming;
//   * **every step saves as it is completed** — a dead battery at step three
//     resumes at step three, because the venue row exists from step one;
//   * a starter catalog instead of a blank menu, since typing thirty services
//     on a phone is how people abandon this.
import { useCallback, useEffect, useState } from 'react';
import { useTranslation } from 'react-i18next';
import { Link, useNavigate } from 'react-router-dom';
import { gql, setActiveVenue } from '../lib/gql';
import { useAuth } from '../lib/auth';
import { Icon } from '../lib/icons';
import type { OnboardingState, VenueSummary } from '../lib/types';
import PhoneAuth from './PhoneAuth';
import '../bungee/bungee.css';
import './home.css';
import './auth.css';

interface Catalog {
  catalog: string;
  serviceCount: number;
}

interface Template {
  id: string;
  category: string;
  name: string;
  durationMin: number;
  priceHintCents: number;
}

const MY_VENUES = `{
  myVenues { id role venue { id slug name status rejectedReason onboarding {
    currentStep completed submitted complete data
  } } }
}`;

const CATALOGS = `{ serviceCatalogs { catalog serviceCount } }`;

const TEMPLATES = `query($catalog: String!, $locale: String) {
  serviceTemplates(catalog: $catalog) {
    id category durationMin priceHintCents name(locale: $locale)
  }
}`;

const CREATE_VENUE = `mutation($name: String!, $city: String, $phone: String) {
  createVenue(name: $name, city: $city, phone: $phone) { id slug name status }
}`;

const UPDATE_STEP = `mutation($step: String!, $data: Json) {
  updateOnboarding(step: $step, data: $data) { id }
}`;

const APPLY = `mutation($ids: [ID!]!, $locale: String) {
  applyServiceTemplates(templateIds: $ids, locale: $locale) { id name }
}`;

const SUBMIT = `mutation { submitVenue { id status } }`;

const CATALOG_LABELS: Record<string, string> = {
  coiffure_femme: 'onboard.womensHair',
  coiffure_homme: 'onboard.mensHair',
  barbier: 'Barbershop',
  onglerie: 'Nails',
  hammam_spa: 'onboard.hammamSpa',
};

const STEPS = ['basics', 'category', 'services', 'team', 'hours', 'review'] as const;
type Step = (typeof STEPS)[number];

export default function OnboardVenue() {
  const { t } = useTranslation();
  const { user, loading, refreshMe } = useAuth();
  const navigate = useNavigate();

  const [venue, setVenue] = useState<VenueSummary | null>(null);
  const [state, setState] = useState<OnboardingState | null>(null);
  const [step, setStep] = useState<Step>('basics');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');

  useEffect(() => {
    document.title = t('onboard.pageTitle');
  }, []);

  // Resume: if this account already started a venue, pick up where it stopped
  // rather than making them begin again.
  const loadExisting = useCallback(async () => {
    if (!user) return;
    try {
      const d = await gql<{ myVenues: { venue: VenueSummary }[] }>(MY_VENUES);
      const pending = d.myVenues?.find((m) => m.venue.status === 'pending');
      if (!pending) return;

      setVenue(pending.venue);
      setActiveVenue(pending.venue.slug);
      const onboarding = pending.venue.onboarding ?? null;
      setState(onboarding);
      if (onboarding?.currentStep) setStep(nextAfter(onboarding.currentStep as Step));
    } catch {
      // A failure here only costs the resume; the wizard still works forwards.
    }
  }, [user]);

  useEffect(() => {
    loadExisting();
  }, [loadExisting]);

  const run = async (work: () => Promise<void>) => {
    if (busy) return;
    setBusy(true);
    setError('');
    try {
      await work();
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setBusy(false);
    }
  };

  const saveStep = async (name: Step, data: Record<string, unknown>) => {
    await gql(UPDATE_STEP, { step: name, data: JSON.stringify(data) });
  };

  if (loading) return <Shell><p className="auth-sub">{t(`action.working`)}</p></Shell>;

  // Signing in first: a venue has to belong to somebody, and phone sign-in is
  // one code rather than a password to invent.
  if (!user) {
    return (
      <Shell>
        <h1 className="auth-title">{t(`onboard.heroTitle`)}</h1>
        <p className="auth-sub">
          {t(`onboard.heroSub`)}
        </p>
        <PhoneAuth onDone={() => undefined} />
      </Shell>
    );
  }

  // Already sent for review — whether a moment ago or last week. Inviting an
  // owner to submit a second time, or dropping them on a dashboard that says
  // nothing about it, both read as the form having been lost.
  if (state?.submitted) {
    return (
      <Shell>
        <SubmittedStep venue={venue} onDashboard={() => navigate('/dashboard/calendar')} />
      </Shell>
    );
  }

  const progress = STEPS.indexOf(step) + 1;

  return (
    <Shell>
      <div className="wiz-progress" aria-label={t('onboard.progressAria', { current: progress, total: STEPS.length })}>
        {STEPS.map((s, i) => (
          <span key={s} className={i < progress ? 'done' : ''} />
        ))}
      </div>

      {/* A rejection hands the venue back, so the owner meets the wizard again
          — and has to be told what to change before they walk through it. */}
      {venue?.rejectedReason && (
        <div className="wiz-rejected">
          <b>{t(`onboard.rejectedHeading`)}</b>
          <p>{venue.rejectedReason}</p>
          <p className="fainttext">{t(`onboard.rejectedBody`)}</p>
        </div>
      )}

      <div className="auth-err">{error}</div>

      {step === 'basics' && (
        <BasicsStep
          busy={busy}
          existing={venue}
          onNext={(values) =>
            run(async () => {
              if (!venue) {
                const d = await gql<{ createVenue: VenueSummary }>(CREATE_VENUE, values);
                setVenue(d.createVenue);
                // The dashboard needs to know which venue it is acting on
                // before any step can be saved against it.
                setActiveVenue(d.createVenue.slug);
                await refreshMe();
              }
              await saveStep('basics', values);
              setStep('category');
            })
          }
        />
      )}

      {step === 'category' && (
        <CategoryStep
          busy={busy}
          onNext={(catalog) =>
            run(async () => {
              await saveStep('category', { catalog });
              setState((s) => ({ ...(s as OnboardingState), data: { ...(s?.data ?? {}), category: { catalog } } }));
              setStep('services');
            })
          }
        />
      )}

      {step === 'services' && (
        <ServicesStep
          busy={busy}
          catalog={(state?.data?.category?.catalog as string) ?? 'coiffure_femme'}
          onNext={(ids) =>
            run(async () => {
              if (ids.length) await gql(APPLY, { ids, locale: 'fr' });
              await saveStep('services', { count: ids.length });
              setStep('team');
            })
          }
        />
      )}

      {step === 'team' && (
        <TeamStep
          busy={busy}
          onNext={(size) =>
            run(async () => {
              await saveStep('team', { size });
              setStep('hours');
            })
          }
        />
      )}

      {step === 'hours' && (
        <HoursStep
          busy={busy}
          onNext={(values) =>
            run(async () => {
              await saveStep('hours', values);
              setStep('review');
            })
          }
        />
      )}

      {step === 'review' && (
        <ReviewStep
          busy={busy}
          venue={venue}
          onSubmit={() =>
            run(async () => {
              await saveStep('review', { confirmed: true });
              await gql(SUBMIT);
              await refreshMe();
              await loadExisting();
            })
          }
          onSkip={() => navigate('/dashboard/calendar')}
        />
      )}
    </Shell>
  );
}

function nextAfter(step: Step): Step {
  const i = STEPS.indexOf(step);
  return STEPS[Math.min(i + 1, STEPS.length - 1)];
}

function Shell({ children }: { children: React.ReactNode }) {
  const { t } = useTranslation();
  return (
    <div className="bungee blastek-home auth-shell wiz-shell">
      {/* i18n-exempt: the brand name is the same word in every language. */}
      <Link to="/" className="auth-back" aria-label="Blastek">
        <span className="brand-word">blastek</span>
      </Link>
      <div className="auth-grid">
        <div className="auth-form-col">
          <div className="auth-form wiz-form">
            <span className="mono">{t(`onboard.eyebrow`)}</span>
            {children}
          </div>
        </div>
      </div>
    </div>
  );
}

function BasicsStep({
  busy,
  existing,
  onNext,
}: {
  busy: boolean;
  existing: VenueSummary | null;
  onNext: (values: { name: string; city: string; phone: string }) => void;
}) {
  const { t } = useTranslation();
  const [name, setName] = useState(existing?.name ?? '');
  const [city, setCity] = useState(existing?.city ?? '');
  const [phone, setPhone] = useState(existing?.phone ?? '');

  return (
    <>
      <h1 className="auth-title">{t(`onboard.businessStepTitle`)}</h1>
      <p className="auth-sub">{t(`onboard.businessStepSub`)}</p>

      <div className="auth-fields">
        <div className="auth-field">
          <label htmlFor="wiz-name">{t(`onboard.businessName`)}</label>
          <input id="wiz-name" value={name} onChange={(e) => setName(e.target.value)} />
        </div>
        <div className="auth-field">
          <label htmlFor="wiz-city">{t(`onboard.city`)}</label>
          <input id="wiz-city" placeholder={t(`onboard.cityPlaceholder`)} value={city}
            onChange={(e) => setCity(e.target.value)} />
        </div>
        <div className="auth-field">
          <label htmlFor="wiz-phone">{t(`onboard.phone`)}</label>
          <input id="wiz-phone" type="tel" placeholder="05 22 …" value={phone}
            onChange={(e) => setPhone(e.target.value)} />
        </div>
      </div>

      <button className="auth-submit" disabled={busy || !name.trim()}
        onClick={() => onNext({ name: name.trim(), city: city.trim(), phone: phone.trim() })}>
        {busy ? 'Saving…' : 'Continue'}
      </button>
    </>
  );
}

function CategoryStep({ busy, onNext }: { busy: boolean; onNext: (catalog: string) => void }) {
  const { t } = useTranslation();
  const [catalogs, setCatalogs] = useState<Catalog[]>([]);
  const [chosen, setChosen] = useState('');

  useEffect(() => {
    gql<{ serviceCatalogs: Catalog[] }>(CATALOGS)
      .then((d) => setCatalogs(d.serviceCatalogs ?? []))
      .catch(() => setCatalogs([]));
  }, []);

  return (
    <>
      <h1 className="auth-title">{t(`onboard.typeStepTitle`)}</h1>
      <p className="auth-sub">{t(`onboard.typeStepSub`)}</p>

      <div className="wiz-choices">
        {catalogs.map((c) => (
          <button
            key={c.catalog}
            className={`wiz-choice${chosen === c.catalog ? ' active' : ''}`}
            onClick={() => setChosen(c.catalog)}
          >
            <b>{CATALOG_LABELS[c.catalog] ?? c.catalog}</b>
            <span className="fainttext">{c.serviceCount} ready-made services</span>
          </button>
        ))}
      </div>

      <button className="auth-submit" disabled={busy || !chosen} onClick={() => onNext(chosen)}>
        {busy ? 'Saving…' : 'Continue'}
      </button>
    </>
  );
}

function ServicesStep({
  busy,
  catalog,
  onNext,
}: {
  busy: boolean;
  catalog: string;
  onNext: (ids: string[]) => void;
}) {
  const { t } = useTranslation();
  const [templates, setTemplates] = useState<Template[]>([]);
  const [chosen, setChosen] = useState<string[]>([]);

  useEffect(() => {
    gql<{ serviceTemplates: Template[] }>(TEMPLATES, { catalog, locale: 'fr' })
      .then((d) => {
        setTemplates(d.serviceTemplates ?? []);
        // Pre-ticked: the fast path is "yes, all of these", and unticking three
        // is quicker than ticking twelve.
        setChosen((d.serviceTemplates ?? []).map((t) => t.id));
      })
      .catch(() => setTemplates([]));
  }, [catalog]);

  const toggle = (id: string) =>
    setChosen((ids) => (ids.includes(id) ? ids.filter((x) => x !== id) : [...ids, id]));

  return (
    <>
      <h1 className="auth-title">{t(`onboard.menuStepTitle`)}</h1>
      <p className="auth-sub">
        {t(`onboard.menuSub`)}
      </p>

      <div className="wiz-services">
        {templates.map((t) => (
          <label key={t.id} className={chosen.includes(t.id) ? 'active' : ''}>
            <input type="checkbox" checked={chosen.includes(t.id)} onChange={() => toggle(t.id)} />
            <span>
              <b>{t.name}</b>
              <span className="fainttext">
                {t.durationMin} min · {Math.round(t.priceHintCents / 100)} MAD
              </span>
            </span>
          </label>
        ))}
      </div>

      <button className="auth-submit" disabled={busy} onClick={() => onNext(chosen)}>
        {busy ? 'Adding…' : `Add ${chosen.length} service${chosen.length === 1 ? '' : 's'}`}
      </button>
    </>
  );
}

function TeamStep({ busy, onNext }: { busy: boolean; onNext: (size: string) => void }) {
  const { t } = useTranslation();
  const sizes = [t('onboard.justMe'), '2–3', '4–6', '7 or more'];

  return (
    <>
      <h1 className="auth-title">{t(`onboard.teamStepTitle`)}</h1>
      <p className="auth-sub">{t(`onboard.teamStepSub`)}</p>

      <div className="wiz-choices">
        {sizes.map((size) => (
          <button key={size} className="wiz-choice" disabled={busy} onClick={() => onNext(size)}>
            <b>{size}</b>
          </button>
        ))}
      </div>
    </>
  );
}

function HoursStep({
  busy,
  onNext,
}: {
  busy: boolean;
  onNext: (values: Record<string, unknown>) => void;
}) {
  const { t } = useTranslation();
  const [opens, setOpens] = useState('09:00');
  const [closes, setCloses] = useState('19:00');

  return (
    <>
      <h1 className="auth-title">{t(`onboard.hoursStepTitle`)}</h1>
      <p className="auth-sub">
        {t(`onboard.hoursSub`)}
      </p>

      <div className="auth-row2">
        <div className="auth-field">
          <label htmlFor="wiz-open">{t(`onboard.opens`)}</label>
          <input id="wiz-open" type="time" value={opens} onChange={(e) => setOpens(e.target.value)} />
        </div>
        <div className="auth-field">
          <label htmlFor="wiz-close">{t(`onboard.closes`)}</label>
          <input id="wiz-close" type="time" value={closes} onChange={(e) => setCloses(e.target.value)} />
        </div>
      </div>

      <button className="auth-submit" disabled={busy} onClick={() => onNext({ opens, closes })}>
        {busy ? 'Saving…' : 'Continue'}
      </button>
    </>
  );
}

function ReviewStep({
  busy,
  venue,
  onSubmit,
  onSkip,
}: {
  busy: boolean;
  venue: VenueSummary | null;
  onSubmit: () => void;
  onSkip: () => void;
}) {
  const { t } = useTranslation();
  return (
    <>
      <h1 className="auth-title">{t(`onboard.readyTitle`)}</h1>
      <p className="auth-sub">
        Send {venue?.name ?? 'your salon'} for review and we will check it over. Your dashboard
        already works — take bookings by phone, build your catalog, invite your team. Only the
        public page waits for approval.
      </p>

      <button className="auth-submit" disabled={busy} onClick={onSubmit}>
        {busy ? 'Sending…' : t('onboard.submitForReview')}
      </button>

      <button className="auth-toggle" onClick={onSkip}>
        {t(`onboard.notYet`)} <b>take me to the dashboard</b>
      </button>
    </>
  );
}

function SubmittedStep({
  venue,
  onDashboard,
}: {
  venue: VenueSummary | null;
  onDashboard: () => void;
}) {
  const { t } = useTranslation();
  return (
    <>
      <div className="wiz-done" aria-hidden="true">
        <Icon name="check" size={28} />
      </div>

      <h1 className="auth-title">{t(`onboard.sentTitle`)}</h1>
      <p className="auth-sub">
        {venue?.name ?? t('onboard.yourSalonLabel')} is with our team. We usually come back within a working day,
        and you will get a message either way.
      </p>
      <p className="auth-sub">
        {t(`onboard.pendingBody`)}
      </p>

      <button className="auth-submit" onClick={onDashboard}>
        {t(`onboard.toDashboard`)}
      </button>
    </>
  );
}
