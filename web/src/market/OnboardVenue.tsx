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
  myVenues { id role venue { id slug name status onboarding {
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
  coiffure_femme: 'Women’s hair',
  coiffure_homme: 'Men’s hair',
  barbier: 'Barbershop',
  onglerie: 'Nails',
  hammam_spa: 'Hammam & spa',
};

const STEPS = ['basics', 'category', 'services', 'team', 'hours', 'review'] as const;
type Step = (typeof STEPS)[number];

export default function OnboardVenue() {
  const { user, loading, refreshMe } = useAuth();
  const navigate = useNavigate();

  const [venue, setVenue] = useState<VenueSummary | null>(null);
  const [state, setState] = useState<OnboardingState | null>(null);
  const [step, setStep] = useState<Step>('basics');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');

  useEffect(() => {
    document.title = 'Blastek — List your salon';
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

  if (loading) return <Shell><p className="auth-sub">One moment…</p></Shell>;

  // Signing in first: a venue has to belong to somebody, and phone sign-in is
  // one code rather than a password to invent.
  if (!user) {
    return (
      <Shell>
        <h1 className="auth-title">List your salon on Blastek.</h1>
        <p className="auth-sub">
          Ten minutes, from your phone. Start by confirming your number — no password needed.
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
      <div className="wiz-progress" aria-label={`Step ${progress} of ${STEPS.length}`}>
        {STEPS.map((s, i) => (
          <span key={s} className={i < progress ? 'done' : ''} />
        ))}
      </div>

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
  return (
    <div className="bungee blastek-home auth-shell wiz-shell">
      <Link to="/" className="auth-back" aria-label="Blastek home">
        <span className="brand-word">blastek</span>
      </Link>
      <div className="auth-grid">
        <div className="auth-form-col">
          <div className="auth-form wiz-form">
            <span className="mono">( For professionals )</span>
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
  const [name, setName] = useState(existing?.name ?? '');
  const [city, setCity] = useState(existing?.city ?? '');
  const [phone, setPhone] = useState(existing?.phone ?? '');

  return (
    <>
      <h1 className="auth-title">Your salon.</h1>
      <p className="auth-sub">Just the basics — everything is editable later.</p>

      <div className="auth-fields">
        <div className="auth-field">
          <label htmlFor="wiz-name">Salon name</label>
          <input id="wiz-name" value={name} onChange={(e) => setName(e.target.value)} />
        </div>
        <div className="auth-field">
          <label htmlFor="wiz-city">City</label>
          <input id="wiz-city" placeholder="Casablanca" value={city}
            onChange={(e) => setCity(e.target.value)} />
        </div>
        <div className="auth-field">
          <label htmlFor="wiz-phone">Salon phone</label>
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
  const [catalogs, setCatalogs] = useState<Catalog[]>([]);
  const [chosen, setChosen] = useState('');

  useEffect(() => {
    gql<{ serviceCatalogs: Catalog[] }>(CATALOGS)
      .then((d) => setCatalogs(d.serviceCatalogs ?? []))
      .catch(() => setCatalogs([]));
  }, []);

  return (
    <>
      <h1 className="auth-title">What do you do?</h1>
      <p className="auth-sub">This picks a starter menu you can edit.</p>

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
      <h1 className="auth-title">Your menu.</h1>
      <p className="auth-sub">
        Untick anything you do not offer. Prices are suggestions — change them any time.
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
  const sizes = ['Just me', '2–3', '4–6', '7 or more'];

  return (
    <>
      <h1 className="auth-title">How many of you?</h1>
      <p className="auth-sub">You can invite them properly from the dashboard later.</p>

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
  const [opens, setOpens] = useState('09:00');
  const [closes, setCloses] = useState('19:00');

  return (
    <>
      <h1 className="auth-title">When are you open?</h1>
      <p className="auth-sub">
        A rough weekly shape. Per-day hours, Ramadan schedules and closures all live in Settings.
      </p>

      <div className="auth-row2">
        <div className="auth-field">
          <label htmlFor="wiz-open">Opens</label>
          <input id="wiz-open" type="time" value={opens} onChange={(e) => setOpens(e.target.value)} />
        </div>
        <div className="auth-field">
          <label htmlFor="wiz-close">Closes</label>
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
  return (
    <>
      <h1 className="auth-title">Ready when you are.</h1>
      <p className="auth-sub">
        Send {venue?.name ?? 'your salon'} for review and we will check it over. Your dashboard
        already works — take bookings by phone, build your catalog, invite your team. Only the
        public page waits for approval.
      </p>

      <button className="auth-submit" disabled={busy} onClick={onSubmit}>
        {busy ? 'Sending…' : 'Submit for review'}
      </button>

      <button className="auth-toggle" onClick={onSkip}>
        Not yet — <b>take me to the dashboard</b>
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
  return (
    <>
      <div className="wiz-done" aria-hidden="true">
        <Icon name="check" size={28} />
      </div>

      <h1 className="auth-title">Sent for review.</h1>
      <p className="auth-sub">
        {venue?.name ?? 'Your salon'} is with our team. We usually come back within a working day,
        and you will get a message either way.
      </p>
      <p className="auth-sub">
        Nothing is on hold in the meantime — your dashboard is already live, so you can take
        bookings by phone, finish your catalog and invite your team. Only the public page waits.
      </p>

      {venue?.rejectedReason && (
        <p className="auth-err">
          Last time we asked for a change: {venue.rejectedReason}. We have your update now.
        </p>
      )}

      <button className="auth-submit" onClick={onDashboard}>
        Go to my dashboard
      </button>
    </>
  );
}
