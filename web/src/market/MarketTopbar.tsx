// Marketplace topbar, shared by the venue layout and the account page.
import { Link } from 'react-router-dom';
import { useTranslation } from 'react-i18next';
import { useAuth } from '../lib/auth';
import { initials } from '../lib/format';
import LanguageSwitcher from '../components/LanguageSwitcher';

export default function MarketTopbar({ inFlow = false }: { inFlow?: boolean }) {
  const { user, memberships } = useAuth();
  const { t } = useTranslation();

  return (
    <div className="mkt-topbar">
      <div className="mkt-topbar-inner">
        <Link className="mkt-brand" to="/">blastek</Link>
        {inFlow ? (
          <span className="mkt-flowhint">{t('nav.booking')}</span>
        ) : (
          <div className="mkt-actions">
            <LanguageSwitcher />
            {/* Someone who already runs a venue wants their dashboard; someone
                who does not wants to create one, not a login wall. */}
            <a
              className="btn btn-ghost btn-sm"
              href={memberships.length > 0 ? '/dashboard' : '/for-business'}
              target="_blank"
              rel="noreferrer"
            >
              {memberships.length > 0 ? t('nav.myDashboard') : t('nav.forProfessionals')}
            </a>
            {user ? (
              <Link
                className="avatar topbar-avatar"
                title={`${user.firstName} ${user.lastName} — ${t('nav.myAppointments')}`}
                to="/account"
              >
                {initials(`${user.firstName} ${user.lastName}`)}
              </Link>
            ) : (
              <Link className="btn btn-ghost btn-sm" to="/login">{t('nav.login')}</Link>
            )}
            <Link className="btn btn-accent btn-sm" to="/venues">{t('nav.bookNow')}</Link>
          </div>
        )}
      </div>
    </div>
  );
}
