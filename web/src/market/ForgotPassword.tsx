// Password reset, both halves (E3-T6 / F0.2): request a link by email, and
// consume one arriving back as `?token=`.
//
// One route serves both because they are two moments in the same task, and a
// separate page for the second would be a URL nobody can reach deliberately.
import { useEffect, useState } from 'react';
import { Link, useNavigate, useSearchParams } from 'react-router-dom';
import { gql } from '../lib/gql';
import '../bungee/bungee.css';
import './home.css';
import './auth.css';

export default function ForgotPassword() {
  const [params] = useSearchParams();
  const navigate = useNavigate();
  const token = params.get('token');

  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [sent, setSent] = useState(false);
  const [error, setError] = useState('');
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    document.title = 'Blastek — Reset your password';
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
      <Link to="/" className="auth-back" aria-label="Blastek home">
        <span className="brand-word">blastek</span>
      </Link>

      <div className="auth-grid">
        <div className="auth-form-col">
          <div className="auth-form">
            <span className="mono">( Reset )</span>

            {token ? (
              <>
                <h1 className="auth-title">Choose a new password.</h1>
                <p className="auth-sub">
                  Setting a new password signs you out everywhere else.
                </p>

                <div className="auth-fields">
                  <div className="auth-field">
                    <label htmlFor="new-password">New password — min 8 characters</label>
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
                  {busy ? 'Saving…' : 'Set new password'}
                </button>
              </>
            ) : sent ? (
              <>
                <h1 className="auth-title">Check your inbox.</h1>
                <p className="auth-sub">
                  If an account exists for {email}, a reset link is on its way. It is valid for
                  one hour.
                </p>
                <Link className="auth-submit auth-submit-link" to="/login">
                  Back to sign in
                </Link>
              </>
            ) : (
              <>
                <h1 className="auth-title">Forgot your password?</h1>
                <p className="auth-sub">
                  Enter your email and we will send you a link. Signed up with a phone number
                  instead? Just sign in with a code — no password needed.
                </p>

                <div className="auth-fields">
                  <div className="auth-field">
                    <label htmlFor="reset-email">Email</label>
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
                  {busy ? 'Sending…' : 'Send reset link'}
                </button>

                <button className="auth-toggle" onClick={() => navigate('/login')}>
                  Back to <b>sign in</b>
                </button>
              </>
            )}
          </div>
        </div>
      </div>
    </div>
  );
}
