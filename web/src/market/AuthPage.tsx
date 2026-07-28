// Blastek client login / signup — same design language as the homepage (Bungee
// system): split screen with an arch-topped salon photo + a minimal form.
// Layout, form state and submit lifecycle live in AuthShell.
import { useEffect } from 'react';
import { useNavigate, useSearchParams } from 'react-router-dom';
import { useAuth } from '../lib/auth';
import AuthShell, { AuthField, safeNext, useAuthForm } from './AuthShell';

export default function AuthPage({ mode }: { mode: 'login' | 'signup' }) {
  const { login, signUp } = useAuth();
  const navigate = useNavigate();
  const [params] = useSearchParams();
  const next = safeNext(params.get('next'));
  const nextQ = next !== '/' ? `?next=${encodeURIComponent(next)}` : '';
  const isLogin = mode === 'login';

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

  return (
    <AuthShell
      media={{ eyebrow: 'Blastek®', heading: <>Book beauty &amp; wellness across Morocco.</> }}
      eyebrow={isLogin ? 'Log in' : 'Sign up'}
      title={isLogin ? 'Welcome back.' : 'Create your account.'}
      sub={
        isLogin
          ? 'Sign in to book and manage your appointments.'
          : 'One account for all your bookings — book, reschedule and cancel with ease.'
      }
      form={form}
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
      demo={isLogin ? 'leila.bennani@example.com · blastek123' : undefined}
    />
  );
}
