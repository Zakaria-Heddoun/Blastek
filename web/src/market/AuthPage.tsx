// Blastek client login / signup — same design language as the homepage (Bungee
// system): split screen with an arch-topped salon photo + a minimal form.
// Layout, form state and submit lifecycle live in AuthShell.
//
// Two ways in (F0.2): a phone number and a texted code, or the original email
// and password. Phone is the default because it is how most Moroccan customers
// will arrive — there is no password to invent or forget.
import { useEffect, useState } from 'react';
import { useNavigate, useSearchParams } from 'react-router-dom';
import { useAuth } from '../lib/auth';
import AuthShell, { AuthField, safeNext, useAuthForm } from './AuthShell';
import PhoneAuth from './PhoneAuth';

export default function AuthPage({ mode }: { mode: 'login' | 'signup' }) {
  const { login, signUp } = useAuth();
  const navigate = useNavigate();
  const [params] = useSearchParams();
  const next = safeNext(params.get('next'));
  const nextQ = next !== '/' ? `?next=${encodeURIComponent(next)}` : '';
  const isLogin = mode === 'login';

  const [method, setMethod] = useState<'phone' | 'email'>('phone');

  useEffect(() => {
    document.title = isLogin ? 'Blastek — Log in' : 'Blastek — Sign up';
    window.scrollTo(0, 0);
  }, [isLogin]);

  const form = useAuthForm(async (f) => {
    if (isLogin) {
      await login(f.email, f.password);
    } else {
      const { businessName: _ignored, ...customer } = f;
      await signUp(customer);
    }
    navigate(next);
  });

  const methodToggle = (
    <div className="auth-methods" role="group" aria-label="Sign-in method">
      <button
        className={method === 'phone' ? 'active' : ''}
        aria-pressed={method === 'phone'}
        onClick={() => setMethod('phone')}
      >
        Phone
      </button>
      <button
        className={method === 'email' ? 'active' : ''}
        aria-pressed={method === 'email'}
        onClick={() => setMethod('email')}
      >
        Email
      </button>
    </div>
  );

  return (
    <AuthShell
      media={{ eyebrow: 'Blastek®', heading: <>Book beauty &amp; wellness across Morocco.</> }}
      eyebrow={isLogin ? 'Log in' : 'Sign up'}
      title={isLogin ? 'Welcome back.' : 'Create your account.'}
      sub={
        method === 'phone'
          ? 'Enter your phone number and we will text you a code.'
          : isLogin
            ? 'Sign in to book and manage your appointments.'
            : 'One account for all your bookings — book, reschedule and cancel with ease.'
      }
      form={form}
      // The phone flow owns its own steps, buttons and errors, so AuthShell
      // renders it whole instead of wrapping it in the shared submit chrome.
      body={method === 'phone' ? <PhoneAuth onDone={() => navigate(next)} /> : undefined}
      above={methodToggle}
      fields={
        <>
          {!isLogin && (
            <>
              <div className="auth-row2">
                <AuthField label="First name" name="firstName" form={form} />
                <AuthField label="Last name" name="lastName" form={form} />
              </div>
              <AuthField label="Phone" name="phone" placeholder="+212 6 …" form={form} />
            </>
          )}
          <AuthField label="Email" name="email" type="email" form={form} />
          <AuthField
            label={`Password${isLogin ? '' : ' — min 8 characters'}`}
            name="password"
            type="password"
            form={form}
          />
          {isLogin && (
            <div className="auth-forgot">
              <button className="linky" onClick={() => navigate('/forgot-password')}>
                Forgot your password?
              </button>
            </div>
          )}
        </>
      }
      submitLabel={isLogin ? 'Sign in' : 'Create account'}
      toggle={
        isLogin ? (
          <>Don’t have an account? <b>Sign up</b></>
        ) : (
          <>Already have an account? <b>Sign in</b></>
        )
      }
      onToggle={() => navigate(`/${isLogin ? 'signup' : 'login'}${nextQ}`)}
      demo={isLogin && method === 'email' ? 'leila.bennani@example.com · blastek123' : undefined}
    />
  );
}
