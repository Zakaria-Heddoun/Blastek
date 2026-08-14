// Blastek client login / signup — same design language as the homepage (Bungee
// system): split screen with an arch-topped salon photo + a minimal form.
// Layout, form state and submit lifecycle live in AuthShell.
//
// Two ways in (F0.2): a phone number and a texted code, or the original email
// and password. Phone is the default because it is how most Moroccan customers
// will arrive — there is no password to invent or forget.
import { useEffect, useState } from 'react';
import { useNavigate, useSearchParams } from 'react-router-dom';
import { useTranslation } from 'react-i18next';
import { useAuth } from '../lib/auth';
import AuthShell, { AuthField, safeNext, useAuthForm } from './AuthShell';
import PhoneAuth from './PhoneAuth';

export default function AuthPage({ mode }: { mode: 'login' | 'signup' }) {
  const { t } = useTranslation();
  const { login, signUp } = useAuth();
  const navigate = useNavigate();
  const [params] = useSearchParams();
  const next = safeNext(params.get('next'));
  const nextQ = next !== '/' ? `?next=${encodeURIComponent(next)}` : '';
  const isLogin = mode === 'login';

  const [method, setMethod] = useState<'phone' | 'email'>('phone');

  useEffect(() => {
    document.title = `Blastek — ${isLogin ? t('auth.login') : t('auth.signup')}`;
    window.scrollTo(0, 0);
  }, [isLogin, t]);

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
    <div className="auth-methods" role="group" aria-label={t(`auth.signInMethod`)}>
      <button
        className={method === 'phone' ? 'active' : ''}
        aria-pressed={method === 'phone'}
        onClick={() => setMethod('phone')}
      >
        {t(`auth.methodPhone`)}
      </button>
      <button
        className={method === 'email' ? 'active' : ''}
        aria-pressed={method === 'email'}
        onClick={() => setMethod('email')}
      >
        {t(`auth.methodEmail`)}
      </button>
    </div>
  );

  return (
    <AuthShell
      media={{ eyebrow: 'Blastek®', heading: <>{t('auth.mediaHeading')}</> }}
      eyebrow={isLogin ? t('auth.login') : t('auth.signup')}
      title={isLogin ? t('auth.loginTitle') : t('auth.signupTitle')}
      sub={
        method === 'phone'
          ? t('auth.phoneSub')
          : isLogin
            ? t('auth.loginSub')
            : t('auth.signupSub')
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
                <AuthField label={t(`auth.firstName`)} name="firstName" form={form} />
                <AuthField label={t(`auth.lastName`)} name="lastName" form={form} />
              </div>
              <AuthField label={t(`common.phone`)} name="phone" placeholder={t(`auth.phonePlaceholder`)} form={form} />
            </>
          )}
          <AuthField label={t(`common.email`)} name="email" type="email" form={form} />
          <AuthField
            label={isLogin ? t('common.password') : t('auth.passwordMin')}
            name="password"
            type="password"
            form={form}
          />
          {isLogin && (
            <div className="auth-forgot">
              <button className="linky" onClick={() => navigate('/forgot-password')}>
                {t(`auth.forgotPassword`)}
              </button>
            </div>
          )}
        </>
      }
      submitLabel={isLogin ? t('auth.signIn') : t('auth.createAccount')}
      toggle={
        isLogin ? (
          <>{t('auth.noAccount')} <b>{t('auth.createOne')}</b></>
        ) : (
          <>{t('auth.haveAccount')} <b>{t('auth.logIn')}</b></>
        )
      }
      onToggle={() => navigate(`/${isLogin ? 'signup' : 'login'}${nextQ}`)}
      // i18n-exempt: demo credentials, not copy.
      demo={isLogin && method === 'email' ? 'leila.bennani@example.com · blastek123' : undefined}
    />
  );
}
