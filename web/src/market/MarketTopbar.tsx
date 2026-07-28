// Marketplace topbar, shared by the venue layout and the account page.
import { Link } from 'react-router-dom';
import { useAuth } from '../lib/auth';
import { initials } from '../lib/format';

export default function MarketTopbar({ inFlow = false }: { inFlow?: boolean }) {
  const { user, memberships } = useAuth();

  return (
    <div className="mkt-topbar">
      <div className="mkt-topbar-inner">
        <Link className="mkt-brand" to="/">blastek</Link>
        {inFlow ? (
          <span className="mkt-flowhint">Booking</span>
        ) : (
          <div className="mkt-actions">
            <a className="btn btn-ghost btn-sm" href="/dashboard" target="_blank" rel="noreferrer">
              {memberships.length > 0 ? 'My dashboard' : 'For professionals'}
            </a>
            {user ? (
              <Link className="avatar topbar-avatar" title={`${user.firstName} ${user.lastName} — my appointments`}
                to="/account">{initials(`${user.firstName} ${user.lastName}`)}</Link>
            ) : (
              <Link className="btn btn-ghost btn-sm" to="/login">Log in</Link>
            )}
            <Link className="btn btn-accent btn-sm" to="/venues">Book now</Link>
          </div>
        )}
      </div>
    </div>
  );
}
