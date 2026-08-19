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
import { AnimatePresence, motion } from 'framer-motion';
import { useTranslation } from 'react-i18next';
import { Link, Navigate, useLocation, useNavigate } from 'react-router-dom';
import { gql, setActiveVenue } from '../lib/gql';
import { useAuth } from '../lib/auth';
import type { User } from '../lib/auth';
import { Icon } from '../lib/icons';
import type { OnboardingState, VenueSummary } from '../lib/types';
import { IMG } from './assets';
import '../bungee/bungee.css';
import './home.css';
import './auth.css';
import './onboarding.css';

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
  barbier: 'onboard.barbershop',
  onglerie: 'onboard.nails',
  hammam_spa: 'onboard.hammamSpa',
};

const STEPS = ['basics', 'category', 'services', 'team', 'hours', 'review'] as const;
type Step = (typeof STEPS)[number];

export default function OnboardVenue() {
  const { t } = useTranslation();
  const { user, loading, refreshMe } = useAuth();
  const navigate = useNavigate();
  const location = useLocation();

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

  if (loading) return <Shell step="basics"><p className="auth-sub">{t(`action.working`)}</p></Shell>;

  // Account creation and returning-owner sign-in live on /for-business. The
  // wizard is only entered from its explicit create action, or resumed for an
  // account that already owns a pending venue.
  if (!user) return <Navigate to="/for-business" replace />;

  const startRequested = Boolean((location.state as { start?: boolean } | null)?.start);
  const resumable = user.venues.some((membership) => membership.venue.status === 'pending');
  if (!startRequested && !resumable) return <Navigate to="/for-business" replace />;

  // Already sent for review — whether a moment ago or last week. Inviting an
  // owner to submit a second time, or dropping them on a dashboard that says
  // nothing about it, both read as the form having been lost.
  if (state?.submitted) {
    return (
      <Shell step="review" progress={STEPS.length} venueName={venue?.name}>
        <SubmittedStep venue={venue} onDashboard={() => navigate('/dashboard/calendar')} />
      </Shell>
    );
  }

  const progress = STEPS.indexOf(step) + 1;

  return (
    <Shell step={step} progress={progress} venueName={venue?.name}>
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

      <AnimatePresence mode="wait">
        <motion.div
          key={step}
          className="pro-onboard-step"
          initial={{ opacity: 0, y: 14 }}
          animate={{ opacity: 1, y: 0 }}
          exit={{ opacity: 0, y: -10 }}
          transition={{ duration: 0.25, ease: 'easeOut' }}
        >
      {step === 'basics' && (
        <BasicsStep
          busy={busy}
          existing={venue}
          account={user}
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
        </motion.div>
      </AnimatePresence>
    </Shell>
  );
}

function nextAfter(step: Step): Step {
  const i = STEPS.indexOf(step);
  return STEPS[Math.min(i + 1, STEPS.length - 1)];
}

const STEP_IMAGES: Record<Step, string> = {
  basics: IMG.salon1,
  category: IMG.barber3,
  services: IMG.hair2,
  team: IMG.hair1,
  hours: IMG.spa2,
  review: IMG.salon1,
};

function Shell({ children, step = 'basics', progress = 1, venueName }: {
  children: React.ReactNode;
  step?: Step;
  progress?: number;
  venueName?: string;
}) {
  const { t } = useTranslation();
  return (
    <div className="bungee blastek-home pro-onboard wiz-shell">
      <aside className="pro-onboard-visual">
        <AnimatePresence mode="wait">
          <motion.img
            key={STEP_IMAGES[step]}
            src={STEP_IMAGES[step]}
            alt=""
            initial={{ opacity: 0, scale: 1.035 }}
            animate={{ opacity: 1, scale: 1 }}
            exit={{ opacity: 0 }}
            transition={{ duration: 0.42 }}
          />
        </AnimatePresence>
        {/* i18n-exempt: brand name, unchanged in every language. */}
        <Link to="/" className="pro-onboard-brand" aria-label="Blastek">
          <span className="brand-word">blastek</span>
        </Link>
        <div className="pro-onboard-visual-copy">
          <span className="mono">{String(progress).padStart(2, '0')} / {String(STEPS.length).padStart(2, '0')}</span>
          <h2>{venueName || t(`onboard.visual.${step}`)}</h2>
          <p>{t(`onboard.visualLead.${step}`)}</p>
        </div>
      </aside>

      <main className="pro-onboard-workspace">
        <nav className="pro-onboard-rail" aria-label={t('onboard.progressAria', { current: progress, total: STEPS.length })}>
          {STEPS.map((item, index) => (
            <span key={item} className={index < progress ? 'active' : ''} aria-current={item === step ? 'step' : undefined}>
              <i>{String(index + 1).padStart(2, '0')}</i>
              <b>{t(`onboard.stepLabels.${item}`)}</b>
            </span>
          ))}
        </nav>
        <div className="pro-onboard-form-col">
          <div className="auth-form wiz-form pro-onboard-form">
            <span className="mono">{t(`onboard.eyebrow`)}</span>
            {children}
          </div>
        </div>
      </main>
    </div>
  );
}

function BasicsStep({
  busy,
  existing,
  account,
  onNext,
}: {
  busy: boolean;
  existing: VenueSummary | null;
  account: User;
  onNext: (values: { name: string; city: string; phone: string }) => void;
}) {
  const { t } = useTranslation();
  const [name, setName] = useState(existing?.name ?? '');
  const [city, setCity] = useState(existing?.city ?? '');
  const [phone, setPhone] = useState(existing?.phone ?? '');

  // Email signup may create the pending venue just before this route mounts.
  // Its GraphQL lookup can finish after the first render, so hydrate any blank
  // fields when that existing venue arrives without overwriting typed input.
  useEffect(() => {
    if (!existing) return;
    setName((value) => value || existing.name || '');
    setCity((value) => value || existing.city || '');
    setPhone((value) => value || existing.phone || '');
  }, [existing]);

  return (
    <>
      <h1 className="auth-title">{t(`onboard.businessStepTitle`)}</h1>
      <p className="auth-sub">{t(`onboard.businessStepSub`)}</p>

      <div className="pro-account-context">
        <span className="pro-account-context-icon"><Icon name="user" size={20} /></span>
        <span>
          <small>{t('onboard.accountAttached')}</small>
          <strong>{account.email || account.phone}</strong>
          <em>
            {account.email
              ? t('onboard.signInAgainEmail')
              : t('onboard.signInAgainPhone')}
          </em>
        </span>
        <Link to="/account?tab=security">{t('onboard.manageLogin')}</Link>
      </div>

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
        {busy ? t('common.saving') : t('common.continue')}
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
            <b>{CATALOG_LABELS[c.catalog] ? t(CATALOG_LABELS[c.catalog]) : c.catalog}</b>
            <span className="fainttext">{t('onboard.readyMadeServices', { count: c.serviceCount })}</span>
          </button>
        ))}
      </div>

      <button className="auth-submit" disabled={busy || !chosen} onClick={() => onNext(chosen)}>
        {busy ? t('common.saving') : t('common.continue')}
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
            <input type="checkbox" className="toggle-switch" checked={chosen.includes(t.id)} onChange={() => toggle(t.id)} />
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
        {busy ? t('onboard.adding') : t('onboard.addServices', { count: chosen.length })}
      </button>
    </>
  );
}

function TeamStep({ busy, onNext }: { busy: boolean; onNext: (size: string) => void }) {
  const { t } = useTranslation();
  const sizes = [t('onboard.justMe'), t('onboard.teamTwoThree'), t('onboard.teamFourSix'), t('onboard.teamSevenPlus')];

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
        {busy ? t('common.saving') : t('common.continue')}
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
        {t('onboard.reviewBody', { name: venue?.name ?? t('onboard.yourSalonLabel') })}
      </p>

      <button className="auth-submit" disabled={busy} onClick={onSubmit}>
        {busy ? t('onboard.sending') : t('onboard.submitForReview')}
      </button>

      <button className="auth-toggle" onClick={onSkip}>
        {t(`onboard.notYet`)} <b>{t('onboard.takeToDashboard')}</b>
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
        {t('onboard.sentBody', { name: venue?.name ?? t('onboard.yourSalonLabel') })}
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
