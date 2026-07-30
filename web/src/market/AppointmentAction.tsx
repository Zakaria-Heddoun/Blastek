// The page a one-tap link from a WhatsApp message lands on (E6-T8 / F0.10).
//
// The work is done by the API the moment this loads; this exists so the person
// who tapped sees something other than raw JSON. It is deliberately the
// simplest page in the app: it is opened on a phone, on mobile data, by
// somebody who is not signed in and did not choose to visit a website.
import { useCallback, useEffect, useState } from 'react';
import { Link, useParams } from 'react-router-dom';
import { Icon } from '../lib/icons';
import './auth.css';

type Result =
  | { state: 'working' }
  | { state: 'done'; action: string; already: boolean }
  | { state: 'failed'; error: string };

export default function AppointmentAction() {
  const { action = '', token = '' } = useParams();
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
      else setResult({ state: 'failed', error: body.error ?? 'This link is no longer valid.' });
    } catch {
      // Distinguished from "the link is invalid", because the two need
      // completely different things from the reader: one is retry, the other is
      // telephone the salon.
      setResult({
        state: 'failed',
        error: 'We could not reach Blastek. Check your connection and try again.',
      });
    }
  }, [action, token]);

  useEffect(() => {
    document.title = 'Blastek';
    run();
  }, [run]);

  return (
    <div className="bungee blastek-home auth-shell wiz-shell">
      <Link to="/" className="auth-back" aria-label="Blastek home">
        <span className="brand-word">blastek</span>
      </Link>

      <div className="auth-grid">
        <div className="auth-form-col">
          <div className="auth-form wiz-form">
            {result.state === 'working' && <p className="auth-sub">One moment…</p>}

            {result.state === 'done' && <Done action={result.action} already={result.already} />}

            {result.state === 'failed' && (
              <>
                <h1 className="auth-title">That link did not work.</h1>
                <p className="auth-sub">{result.error}</p>
                <button className="auth-submit" onClick={run}>Try again</button>
                <Link className="auth-toggle" to="/account">
                  Or <b>open my appointments</b>
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
  const cancelled = action === 'cancel';

  return (
    <>
      <div className="wiz-done" aria-hidden="true">
        <Icon name="check" size={28} />
      </div>

      <h1 className="auth-title">
        {cancelled ? 'Appointment cancelled.' : 'Appointment confirmed.'}
      </h1>

      <p className="auth-sub">
        {already
          ? 'It was already done — nothing has changed.'
          : cancelled
            ? 'The salon has been told, and the slot is free for somebody else.'
            : 'The salon knows to expect you.'}
      </p>

      {cancelled && (
        <p className="auth-sub">
          Changed your mind? Book again in a moment — the same slot may still be there.
        </p>
      )}

      <Link className="auth-submit" to={cancelled ? '/venues' : '/account'}>
        {cancelled ? 'Find another time' : 'My appointments'}
      </Link>
    </>
  );
}
