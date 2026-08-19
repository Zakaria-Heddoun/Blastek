import { useEffect, useMemo, useState } from 'react';
import { AnimatePresence, motion } from 'framer-motion';
import { useTranslation } from 'react-i18next';
import { Link, Navigate, useNavigate, useSearchParams } from 'react-router-dom';
import { useAuth } from '../lib/auth';
import { gql } from '../lib/gql';
import { Icon, Sparkle } from '../lib/icons';
import { safeNext } from './AuthShell';
import { CITIES, IMG } from './assets';
import '../bungee/bungee.css';
import './home.css';
import './onboarding.css';

const UPDATE_PREFS = `mutation($reminders: Boolean, $marketing: Boolean) {
  updateNotificationPrefs(reminders: $reminders, marketing: $marketing) {
    id notificationPrefs { reminders marketing }
  }
}`;

const TASTES = [
  { id: 'hair', category: 'Hair', icon: 'scissors', image: IMG.hair2, color: '#e7d8f5' },
  { id: 'barber', category: 'Barbering', icon: 'scissors', image: IMG.barber2, color: '#c8e4d5' },
  { id: 'nails', category: 'Nails', icon: 'star', image: IMG.nails2, color: '#f3d4cc' },
  // i18n-exempt: GraphQL category identifier, never rendered as interface copy.
  { id: 'spa', category: 'Massage & Spa', icon: 'sun', image: IMG.spa1, color: '#f2dd91' },
] as const;

type Step = 'taste' | 'city' | 'notifications';
const STEPS: Step[] = ['taste', 'city', 'notifications'];

export default function CustomerOnboarding() {
  const { t } = useTranslation();
  const { user, loading, refreshMe } = useAuth();
  const navigate = useNavigate();
  const [params] = useSearchParams();
  const explicitNext = params.has('next') ? safeNext(params.get('next')) : null;
  const [step, setStep] = useState<Step>('taste');
  const [taste, setTaste] = useState<(typeof TASTES)[number]['id'] | ''>('');
  const [city, setCity] = useState('');
  const [reminders, setReminders] = useState(true);
  const [marketing, setMarketing] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');

  useEffect(() => {
    document.title = t('customerOnboard.pageTitle');
    window.scrollTo(0, 0);
  }, [t]);

  useEffect(() => {
    if (!user) return;
    setReminders(user.notificationPrefs?.reminders !== false);
    setMarketing(user.notificationPrefs?.marketing === true);
  }, [user]);

  const index = STEPS.indexOf(step);
  const selectedTaste = TASTES.find((item) => item.id === taste);
  const visual = selectedTaste?.image ?? (step === 'city' ? IMG.salon1 : step === 'notifications' ? IMG.hair3 : IMG.hair2);
  const accent = selectedTaste?.color ?? '#e7d8f5';

  const destination = useMemo(() => {
    if (explicitNext) return explicitNext;
    const query = new URLSearchParams();
    if (selectedTaste) query.set('category', selectedTaste.category);
    if (city.trim()) query.set('city', city.trim());
    const suffix = query.toString();
    return `/venues${suffix ? `?${suffix}` : ''}`;
  }, [city, explicitNext, selectedTaste]);

  const rememberCompletion = () => {
    if (user) localStorage.setItem(`blastek-onboarded:${user.id}`, '1');
  };

  const skip = () => {
    rememberCompletion();
    navigate(explicitNext ?? '/venues');
  };

  const finish = async () => {
    if (busy) return;
    setBusy(true);
    setError('');
    try {
      await gql(UPDATE_PREFS, { reminders, marketing });
      await refreshMe();
      rememberCompletion();
      navigate(destination);
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setBusy(false);
    }
  };

  if (loading) return <main className="app-state" role="status">{t('common.loading')}</main>;
  if (!user) return <Navigate to="/signup?next=/welcome" replace />;

  return (
    <main className="bungee blastek-home customer-onboard" style={{ '--onboard-accent': accent } as React.CSSProperties}>
      <header className="customer-onboard-head">
        {/* i18n-exempt: brand name, unchanged in every language. */}
        <Link to="/" className="customer-onboard-brand" aria-label="Blastek">
          <span className="brand-word">blastek</span>
        </Link>
        <button type="button" className="customer-onboard-skip" onClick={skip}>{t('customerOnboard.skip')}</button>
      </header>

      <section className="customer-onboard-visual" aria-hidden="true">
        <AnimatePresence mode="wait">
          <motion.img
            key={visual}
            src={visual}
            alt=""
            initial={{ opacity: 0, scale: 1.04 }}
            animate={{ opacity: 1, scale: 1 }}
            exit={{ opacity: 0 }}
            transition={{ duration: 0.45, ease: 'easeOut' }}
          />
        </AnimatePresence>
        <div className="customer-onboard-visual-copy">
          <Sparkle size={21} />
          <p>{t(`customerOnboard.visual.${step}`)}</p>
        </div>
      </section>

      <section className="customer-onboard-workspace">
        <div className="customer-onboard-progress" aria-label={t('onboard.progressAria', { current: index + 1, total: STEPS.length })}>
          <span>{String(index + 1).padStart(2, '0')}</span>
          <div>
            {STEPS.map((item, itemIndex) => <i key={item} className={itemIndex <= index ? 'active' : ''} />)}
          </div>
          <span>{String(STEPS.length).padStart(2, '0')}</span>
        </div>

        <AnimatePresence mode="wait">
          <motion.div
            className="customer-onboard-step"
            key={step}
            initial={{ opacity: 0, x: 20 }}
            animate={{ opacity: 1, x: 0 }}
            exit={{ opacity: 0, x: -20 }}
            transition={{ duration: 0.28, ease: 'easeOut' }}
          >
            <span className="customer-onboard-eyebrow">{t(`customerOnboard.steps.${step}`)}</span>

            {step === 'taste' && (
              <>
                <h1>{t('customerOnboard.tasteTitle', { name: user.firstName })}</h1>
                <p className="customer-onboard-lead">{t('customerOnboard.tasteLead')}</p>
                <div className="customer-tastes">
                  {TASTES.map((item) => (
                    <button
                      key={item.id}
                      type="button"
                      className={taste === item.id ? 'active' : ''}
                      style={{ '--taste-color': item.color } as React.CSSProperties}
                      aria-pressed={taste === item.id}
                      onClick={() => setTaste(item.id)}
                    >
                      <span><Icon name={item.icon} size={20} /></span>
                      <b>{t(`customerOnboard.categories.${item.id}`)}</b>
                      <Icon name="right" size={18} />
                    </button>
                  ))}
                </div>
              </>
            )}

            {step === 'city' && (
              <>
                <h1>{t('customerOnboard.cityTitle')}</h1>
                <p className="customer-onboard-lead">{t('customerOnboard.cityLead')}</p>
                <label className="customer-city-field" htmlFor="onboard-city">
                  <Icon name="pin" size={22} />
                  <input
                    id="onboard-city"
                    list="onboard-cities"
                    autoComplete="address-level2"
                    placeholder={t('customerOnboard.cityPlaceholder')}
                    value={city}
                    onChange={(event) => setCity(event.target.value)}
                    autoFocus
                  />
                </label>
                <datalist id="onboard-cities">{CITIES.map((item) => <option key={item} value={item} />)}</datalist>
                <div className="customer-city-shortcuts">
                  {CITIES.map((item) => (
                    <button key={item} type="button" className={city === item ? 'active' : ''} onClick={() => setCity(item)}>
                      {item}
                    </button>
                  ))}
                </div>
              </>
            )}

            {step === 'notifications' && (
              <>
                <h1>{t('customerOnboard.notificationsTitle')}</h1>
                <p className="customer-onboard-lead">{t('customerOnboard.notificationsLead')}</p>
                <div className="customer-pref-list">
                  <Preference
                    label={t('account.remindersLabel')}
                    hint={t('account.remindersHint')}
                    checked={reminders}
                    onChange={setReminders}
                  />
                  <Preference
                    label={t('account.marketingLabel')}
                    hint={t('account.marketingHint')}
                    checked={marketing}
                    onChange={setMarketing}
                  />
                </div>
                <p className="customer-onboard-note"><Icon name="shield" size={17} />{t('customerOnboard.confirmationNote')}</p>
              </>
            )}

            <div className="customer-onboard-error" role="alert">{error}</div>
            <div className="customer-onboard-actions">
              {index > 0 && (
                <button type="button" className="customer-onboard-back" title={t('common.back')} onClick={() => setStep(STEPS[index - 1])}>
                  <Icon name="left" size={21} />
                </button>
              )}
              <button
                type="button"
                className="customer-onboard-next"
                disabled={busy || (step === 'taste' && !taste)}
                onClick={() => step === 'notifications' ? finish() : setStep(STEPS[index + 1])}
              >
                {busy ? t('common.saving') : step === 'notifications' ? t('customerOnboard.discover') : t('common.continue')}
                {!busy && <Icon name="right" size={19} />}
              </button>
            </div>
          </motion.div>
        </AnimatePresence>
      </section>
    </main>
  );
}

function Preference({ label, hint, checked, onChange }: {
  label: string;
  hint: string;
  checked: boolean;
  onChange: (checked: boolean) => void;
}) {
  return (
    <label className="customer-pref">
      <span><b>{label}</b><small>{hint}</small></span>
      <input className="toggle-switch" type="checkbox" checked={checked} onChange={(event) => onChange(event.target.checked)} />
    </label>
  );
}
