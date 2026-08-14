// Password reset, both halves (E3-T6 / F0.2): request a link by email, and
// consume one arriving back as `?token=`.
//
// One route serves both because they are two moments in the same task, and a
// separate page for the second would be a URL nobody can reach deliberately.
import { useEffect, useState } from 'react';
import { useTranslation } from 'react-i18next';
import { Link, useNavigate, useSearchParams } from 'react-router-dom';
import { gql } from '../lib/gql';
import '../bungee/bungee.css';
import './home.css';
import './auth.css';

export default function ForgotPassword() {
  const { t } = useTranslation();
  const [params] = useSearchParams();
  const navigate = useNavigate();
  const token = params.get('token');

  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [sent, setSent] = useState(false);
  const [error, setError] = useState('');
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    document.title = `Blastek — ${t('auth.resetTitle')}`;
  }, []);

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

  const request = () =>
    run(async () => {
      await gql(`mutation($email: String!) { requestPasswordReset(email: $email) }`, { email });
      // Shown whether or not the address exists — the server deliberately does
      // not say, and neither should this screen.
      setSent(true);
    });

  const reset = () =>
    run(async () => {
      await gql(
        `mutation($token: String!, $password: String!) {
          resetPassword(token: $token, password: $password) }`,
        { token, password },
      );
      navigate('/login?reset=1');
    });

  return (
    <div className="bungee blastek-home auth-shell">
      {/* i18n-exempt: the brand name is the same word in every language. */}
      <Link to="/" className="auth-back" aria-label="Blastek">
        <span className="brand-word">blastek</span>
      </Link>

      <div className="auth-grid">
        <div className="auth-form-col">
          <div className="auth-form">
            <span className="mono">{t(`auth.resetEyebrow`)}</span>

            {token ? (
              <>
                <h1 className="auth-title">{t(`auth.newPasswordTitle`)}</h1>
                <p className="auth-sub">
                  {t(`auth.resetSignsOut`)}
                </p>

                <div className="auth-fields">
                  <div className="auth-field">
                    <label htmlFor="new-password">{t(`auth.newPasswordMin`)}</label>
                    <input
                      id="new-password"
                      type="password"
                      autoComplete="new-password"
                      value={password}
                      onChange={(e) => setPassword(e.target.value)}
                      onKeyDown={(e) => e.key === 'Enter' && reset()}
                    />
                  </div>
                </div>

                <div className="auth-err">{error}</div>

                <button
                  className="auth-submit"
                  disabled={busy || password.length < 8}
                  onClick={reset}
                >
                  {busy ? 'Saving…' : t('auth.setNewPassword')}
                </button>
              </>
            ) : sent ? (
              <>
                <h1 className="auth-title">{t(`auth.checkInbox`)}</h1>
                <p className="auth-sub">
                  If an account exists for {email}, a reset link is on its way. It is valid for
                  one hour.
                </p>
                <Link className="auth-submit auth-submit-link" to="/login">
                  {t(`auth.backToSignIn`)}
                </Link>
              </>
            ) : (
              <>
                <h1 className="auth-title">{t(`auth.resetTitle`)}</h1>
                <p className="auth-sub">
                  {t(`auth.resetHelp`)}
                </p>

                <div className="auth-fields">
                  <div className="auth-field">
                    <label htmlFor="reset-email">{t(`common.email`)}</label>
                    <input
                      id="reset-email"
                      type="email"
                      autoComplete="email"
                      value={email}
                      onChange={(e) => setEmail(e.target.value)}
                      onKeyDown={(e) => e.key === 'Enter' && request()}
                    />
                  </div>
                </div>

                <div className="auth-err">{error}</div>

                <button className="auth-submit" disabled={busy || !email.trim()} onClick={request}>
                  {busy ? 'Sending…' : t('auth.sendResetLink')}
                </button>

                <button className="auth-toggle" onClick={() => navigate('/login')}>
                  {t(`auth.backTo`)} <b>sign in</b>
                </button>
              </>
            )}
          </div>
        </div>
      </div>
    </div>
  );
}
