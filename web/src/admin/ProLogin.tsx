// Professional sign-in — the gate in front of the dashboard, in the
// Blastek/Bungee design system (shares the market auth shell + styles).
//
// Dashboard access comes from venue membership: signing in requires an account
// that manages at least one venue, and signing up creates that venue.
import { useEffect, useState } from 'react';
import { useTranslation } from 'react-i18next';
import { useNavigate } from 'react-router-dom';
import { useAuth } from '../lib/auth';
import AuthShell, { AuthField, useAuthForm } from '../market/AuthShell';

export default function ProLogin() {
  const { t } = useTranslation();
  const { login, signUp, logout } = useAuth();
  const navigate = useNavigate();
  const [mode, setMode] = useState<'login' | 'signup'>('login');
  const isLogin = mode === 'login';

  useEffect(() => {
    document.title = `Blastek — ${t('admin.login.title')}`;
    window.scrollTo(0, 0);
  }, []);

  const form = useAuthForm(async (f) => {
    // Without a salon name the server would create a plain customer account,
    // burning the email on a login that can never reach the dashboard.
    if (!isLogin && !f.businessName.trim()) {
      throw new Error(t('admin.login.needSalonName'));
    }

    const user = isLogin
      ? await login(f.email, f.password)
      : await signUp({
          email: f.email,
          password: f.password,
          firstName: f.firstName,
          lastName: f.lastName,
          businessName: f.businessName.trim(),
        });

    if (user.venues.length === 0) {
      // login/signUp already stored the token — drop it so a rejected sign-in
      // doesn't leave the client silently logged in behind the error message.
      logout();
      throw new Error(t('admin.login.notAVenue'));
    }

    navigate('/dashboard/calendar');
  });

  return (
    <AuthShell
      media={{
        eyebrow: t('admin.login.title'),
        heading: t('admin.login.mediaHeading'),
      }}
      eyebrow={t(`admin.login.title`)}
      title={isLogin ? t('admin.login.signInSub') : t('admin.login.signUpSub')}
      sub={
        isLogin
          ? t('admin.login.signInLead')
          : t('admin.login.signUpLead')
      }
      form={form}
      fields={
        <>
          {!isLogin && (
            <>
              <AuthField label={t(`admin.login.salonName`)} name="businessName" form={form} />
              <div className="auth-row2">
                <AuthField label={t(`auth.firstName`)} name="firstName" form={form} />
                <AuthField label={t(`auth.lastName`)} name="lastName" form={form} />
              </div>
            </>
          )}
          <AuthField label="Email" name="email" type="email" form={form} />
          <AuthField label={t(`common.password`)} name="password" type="password" form={form} />
        </>
      }
      submitLabel={isLogin ? t('auth.signIn') : t('auth.createAccount')}
      toggle={
        isLogin ? (
          <>{t(`admin.login.newHere`)} <b>{t(`admin.login.createBusiness`)}</b></>
        ) : (
          <>{t(`admin.login.alreadyRegistered`)} <b>{t(`auth.signIn`)}</b></>
        )
      }
      onToggle={() => setMode(isLogin ? 'signup' : 'login')}
      // i18n-exempt: demo credentials, not copy.
      demo={isLogin ? 'owner@salonanfa.ma · blastek123' : undefined}
    />
  );
}
