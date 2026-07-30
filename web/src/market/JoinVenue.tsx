// Redeeming a team invitation (E4-T5 / F0.3).
//
// The person arriving here is usually a stranger to Blastek: a receptionist who
// was sent a link by their manager. So the page shows *what is on offer first*,
// signs them in by code second, and joins third. Asking someone to authenticate
// before telling them what they are joining is how people click through things
// they should not.
import { useCallback, useEffect, useState } from 'react';
import { Link, useNavigate, useSearchParams } from 'react-router-dom';
import { gql, setActiveVenue } from '../lib/gql';
import { useAuth } from '../lib/auth';
import PhoneAuth from './PhoneAuth';
import '../bungee/bungee.css';
import './home.css';
import './auth.css';

interface Preview {
  role: string;
  venueName: string;
  venueSlug: string;
  expiresAt: string;
}

const ROLE_COPY: Record<string, string> = {
  owner: 'an owner — full access, including the team',
  manager: 'a manager — catalog, roster, sales and reports',
  receptionist: 'a receptionist — calendar, clients and checkout',
  staff: 'a team member — your own calendar and clients',
};

export default function JoinVenue() {
  const [params] = useSearchParams();
  const token = params.get('token') ?? '';
  const { user, loading, refreshMe } = useAuth();
  const navigate = useNavigate();

  const [preview, setPreview] = useState<Preview | null>(null);
  const [error, setError] = useState('');
  const [joining, setJoining] = useState(false);

  useEffect(() => {
    document.title = 'Blastek — Join a team';
  }, []);

  useEffect(() => {
    if (!token) {
      setError('This link is missing its invitation code.');
      return;
    }

    gql<{ invitation: Preview | null }>(
      `query($token: String!) {
        invitation(token: $token) { role venueName venueSlug expiresAt } }`,
      { token },
    )
      .then((d) => setPreview(d.invitation))
      .catch((e) => setError((e as Error).message));
  }, [token]);

  const join = useCallback(async () => {
    if (joining) return;
    setJoining(true);
    setError('');

    try {
      const d = await gql<{ acceptInvitation: { venue: { slug: string } } }>(
        `mutation($token: String!) {
          acceptInvitation(token: $token) { role venue { slug } } }`,
        { token },
      );

      // Point the dashboard at the venue they just joined, or they land on
      // whichever one they happened to have selected before.
      setActiveVenue(d.acceptInvitation.venue.slug);
      await refreshMe();
      navigate('/dashboard/calendar');
    } catch (e) {
      setError((e as Error).message);
      setJoining(false);
    }
  }, [joining, token, refreshMe, navigate]);

  const body = () => {
    if (error && !preview) {
      return (
        <>
          <h1 className="auth-title">This link has expired.</h1>
          <p className="auth-sub">{error}</p>
          <p className="auth-sub">Ask whoever invited you to send a new one.</p>
          <Link className="auth-submit auth-submit-link" to="/">Back to Blastek</Link>
        </>
      );
    }

    if (!preview) return <p className="auth-sub">Checking your invitation…</p>;

    return (
      <>
        <h1 className="auth-title">Join {preview.venueName}.</h1>
        <p className="auth-sub">
          You have been invited as {ROLE_COPY[preview.role] ?? preview.role}.
        </p>

        {loading ? (
          <p className="auth-sub">One moment…</p>
        ) : user?.profileComplete ? (
          <>
            <p className="auth-hint">
              Signed in as {[user.firstName, user.lastName].filter(Boolean).join(' ') || user.phone}.
            </p>

            <div className="auth-err">{error}</div>

            {/* Accepting is deliberately a second, explicit tap rather than
                something that happens the instant they authenticate — signing
                in should never silently commit you to a membership. */}
            <button className="auth-submit" disabled={joining} onClick={join}>
              {joining ? 'Joining…' : `Join ${preview.venueName}`}
            </button>
          </>
        ) : (
          <>
            <p className="auth-hint">
              {user
                ? 'Almost there — tell us your name.'
                : 'Sign in with your phone to accept. No password needed.'}
            </p>
            {/* Gated on `profileComplete`, not merely on `user`: signing in
                sets the user immediately, and switching on that would unmount
                this component mid-flow — before the invitee has been asked
                their name. They would then join as a bare phone number. */}
            <PhoneAuth onDone={() => undefined} initialStep={user ? 'name' : 'phone'} />
          </>
        )}
      </>
    );
  };

  return (
    <div className="bungee blastek-home auth-shell">
      <Link to="/" className="auth-back" aria-label="Blastek home">
        <span className="brand-word">blastek</span>
      </Link>

      <div className="auth-grid">
        <div className="auth-form-col">
          <div className="auth-form">
            <span className="mono">( Invitation )</span>
            {body()}
          </div>
        </div>
      </div>
    </div>
  );
}
