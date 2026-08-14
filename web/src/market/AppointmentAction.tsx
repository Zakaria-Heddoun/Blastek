// The page a one-tap link from a WhatsApp message lands on (E6-T8 / F0.10).
//
// The work is done by the API the moment this loads; this exists so the person
// who tapped sees something other than raw JSON. It is deliberately the
// simplest page in the app: it is opened on a phone, on mobile data, by
// somebody who is not signed in and did not choose to visit a website.
import { useCallback, useEffect, useState } from 'react';
import { Link, useParams } from 'react-router-dom';
import { Trans, useTranslation } from 'react-i18next';
import { Icon } from '../lib/icons';
import LanguageSwitcher from '../components/LanguageSwitcher';
import './auth.css';

type Result =
  | { state: 'working' }
  | { state: 'done'; action: string; already: boolean }
  | { state: 'failed'; error: string };

export default function AppointmentAction() {
  const { action = '', token = '' } = useParams();
  const { t } = useTranslation();
  const [result, setResult] = useState<Result>({ state: 'working' });

  const run = useCallback(async () => {
    setResult({ state: 'working' });
    try {
      // Relative, like every other call in the app: the browser reaches the API
      // through the same origin, and a link built against the API's own host
      // would be unopenable from a phone.
      const response = await fetch(`/api/a/${encodeURIComponent(action)}/${token}`);
      const body = await response.json();

      if (body.ok) setResult({ state: 'done', action, already: body.already === true });
      else setResult({ state: 'failed', error: body.error ?? t('action.invalidLink') });
    } catch {
      // Distinguished from "the link is invalid", because the two need
      // completely different things from the reader: one is retry, the other is
      // telephone the salon.
      setResult({ state: 'failed', error: t('action.unreachable') });
    }
  }, [action, token, t]);

  useEffect(() => {
    document.title = 'Blastek'; // i18n-exempt: brand name
    run();
  }, [run]);

  return (
    <div className="bungee blastek-home auth-shell wiz-shell">
      <Link to="/" className="auth-back" aria-label={t('auth.backHome')}>
        <span className="brand-word">blastek</span>
      </Link>

      {/* The one page in the app reached by somebody who never chose a language
          here — it arrives from a WhatsApp message. The switcher matters more,
          not less, for that reason. */}
      <div className="auth-lang"><LanguageSwitcher /></div>

      <div className="auth-grid">
        <div className="auth-form-col">
          <div className="auth-form wiz-form">
            {result.state === 'working' && <p className="auth-sub">{t('action.working')}</p>}

            {result.state === 'done' && <Done action={result.action} already={result.already} />}

            {result.state === 'failed' && (
              <>
                <h1 className="auth-title">{t('action.failedTitle')}</h1>
                <p className="auth-sub">{result.error}</p>
                <button className="auth-submit" onClick={run}>{t('common.retry')}</button>
                <Link className="auth-toggle" to="/account">
                  <Trans i18nKey="action.openAppointments" components={{ 1: <b /> }} />
                </Link>
              </>
            )}
          </div>
        </div>
      </div>
    </div>
  );
}

function Done({ action, already }: { action: string; already: boolean }) {
  const { t } = useTranslation();
  const cancelled = action === 'cancel';

  return (
    <>
      <div className="wiz-done" aria-hidden="true">
        <Icon name="check" size={28} />
      </div>

      <h1 className="auth-title">
        {cancelled ? t('action.cancelledTitle') : t('action.confirmedTitle')}
      </h1>

      <p className="auth-sub">
        {already
          ? t('action.alreadyDone')
          : cancelled
            ? t('action.cancelledBody')
            : t('action.confirmedBody')}
      </p>

      {cancelled && <p className="auth-sub">{t('action.rebookHint')}</p>}

      <Link className="auth-submit" to={cancelled ? '/venues' : '/account'}>
        {cancelled ? t('action.findAnother') : t('action.myAppointments')}
      </Link>
    </>
  );
}
