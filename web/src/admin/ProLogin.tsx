// Professional sign-in — the gate in front of the dashboard, in the
// Blastek/Bungee design system (shares the market auth shell + styles).
//
// Dashboard access comes from venue membership: signing in requires an account
// that manages at least one venue, and signing up creates that venue.
import { useEffect, useState } from 'react';
import { useTranslation } from 'react-i18next';
import { Navigate, useNavigate } from 'react-router-dom';
import { useAuth } from '../lib/auth';
import AuthShell, { AuthField, useAuthForm } from '../market/AuthShell';
import '../market/onboarding.css';

export default function ProLogin() {
  const { t } = useTranslation();
  const { user: signedInUser, loading, login, signUp, logout } = useAuth();
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

    if (!isLogin) {
      // Account creation is the explicit boundary before onboarding. The
      // signup mutation may already have created the pending venue; the wizard
      // resumes it instead of creating a duplicate.
      navigate('/for-business/onboarding', { state: { start: true } });
      return;
    }

    // Returning owners go straight to work. A customer who signed in here is
    // shown the professional entry choice; setup does not begin automatically.
    navigate(user.venues.length > 0 ? '/dashboard/calendar' : '/for-business', { replace: true });
  });

  if (loading) return <main className="app-state" role="status">{t('common.loading')}</main>;
  if (signedInUser?.venues.length) {
    return (
      <Navigate
        to="/dashboard/calendar"
        replace
      />
    );
  }

  // A signed-in customer can add a professional profile to this same account,
  // but only after pressing the create button below. Merely visiting the
  // professional entry page must never launch setup.
  if (signedInUser) {
    if (mode === 'signup') {
      return <Navigate to="/for-business/onboarding" state={{ start: true }} replace />;
    }

    return (
      <AuthShell
        media={{ eyebrow: t('admin.login.title'), heading: t('admin.login.mediaHeading') }}
        eyebrow={t('admin.login.title')}
        title={t('admin.login.addBusinessTitle')}
        sub={t('admin.login.addBusinessLead')}
        form={form}
        fields={null}
        body={
          <div className="pro-entry-account">
            <div>
              <span>{t('admin.login.signedInAccount')}</span>
              <strong>{signedInUser.email || signedInUser.phone}</strong>
            </div>
            <button
              type="button"
              className="auth-submit"
              onClick={() => navigate('/for-business/onboarding', { state: { start: true } })}
            >
              {t('admin.login.createBusiness')}
            </button>
          </div>
        }
        submitLabel=""
        toggle={<>{t('admin.login.useAnotherAccount')}</>}
        onToggle={async () => {
          await logout();
        }}
      />
    );
  }

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
          <AuthField label={t('common.email')} name="email" type="email" form={form} />
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
