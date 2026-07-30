// Auth: token in localStorage, `me` on boot, login/signup/logout.
//
// A user's dashboard access comes from venue memberships, not from a global
// role — `user.venues` lists the venues they administer, and the active one is
// sent as a header with every request (see gql.ts).
import { createContext, useCallback, useContext, useEffect, useState } from 'react';
import type { ReactNode } from 'react';
import { ConnectionError, getActiveVenue, gql, setActiveVenue } from './gql';
import type { VenueMembership } from './types';

export interface User {
  id: string;
  email: string | null;
  role: 'customer' | 'admin';
  firstName: string;
  lastName: string;
  phone: string;
  /** The number has been proven by a one-time code. */
  phoneVerified: boolean;
  /** False for an account created by phone that has not been named yet. */
  profileComplete: boolean;
  /** Phone-first accounts start without one. */
  hasPassword: boolean;
  venues: VenueMembership[];
}

/** What `requestOtp` reports back: a masked number and the two countdowns. */
export interface OtpRequest {
  phone: string;
  expiresAt: string;
  resendAfter: number;
}

interface AuthCtx {
  user: User | null;
  loading: boolean;
  /** Venues the signed-in user administers (empty for pure customers). */
  memberships: VenueMembership[];
  /** Slug of the venue the dashboard is currently acting on. */
  activeVenue: string | null;
  selectVenue: (slug: string) => void;
  login: (email: string, password: string) => Promise<User>;
  signUp: (input: { email: string; password: string; firstName: string; lastName?: string;
    phone?: string; businessName?: string }) => Promise<User>;
  /** Step 1 of phone sign-in: send a code. */
  requestOtp: (phone: string) => Promise<OtpRequest>;
  /** Step 2: exchange the code for a session. */
  verifyOtp: (phone: string, code: string) => Promise<User>;
  /** Names an account created by phone. */
  completeProfile: (firstName: string, lastName?: string) => Promise<User>;
  logout: () => Promise<void>;
  refreshMe: () => Promise<void>;
}

const Ctx = createContext<AuthCtx>(null!);
export const useAuth = () => useContext(Ctx);

const USER_FIELDS = `id email role firstName lastName phone
  phoneVerified profileComplete hasPassword
  venues { id role venue { id slug name city status } }`;

const ME = `{ me { ${USER_FIELDS} } }`;

const AUTH_FIELDS = `token refreshToken profileComplete user { ${USER_FIELDS} }`;

const TOKEN_KEY = 'blastek-token';
// Stored beside the access token so a returning visitor can be signed back in
// without another code. It is the longer-lived of the two, so it is also the
// one that must be cleared on logout.
const REFRESH_KEY = 'blastek-refresh';

export function AuthProvider({ children }: { children: ReactNode }) {
  const [user, setUser] = useState<User | null>(null);
  const [loading, setLoading] = useState(true);
  const [activeVenue, setActive] = useState<string | null>(getActiveVenue());

  // Keeps the stored venue header consistent with what the user can actually
  // reach: on sign-in, or when their memberships change.
  const syncVenue = useCallback((u: User | null) => {
    const slugs = (u?.venues ?? []).map((m) => m.venue.slug);
    const current = getActiveVenue();

    if (slugs.length === 0) {
      setActiveVenue(null);
      setActive(null);
    } else if (!current || !slugs.includes(current)) {
      setActiveVenue(slugs[0]);
      setActive(slugs[0]);
    } else {
      setActive(current);
    }
  }, []);

  const refreshMe = useCallback(async () => {
    if (!localStorage.getItem(TOKEN_KEY)) { setUser(null); return; }

    let d = await gql<{ me: User | null }>(ME);

    // An access token lasts a day, a refresh token two months. A null `me` with
    // a refresh token in hand means the short one simply aged out — exchange it
    // rather than making someone sign in again every day.
    if (!d.me && localStorage.getItem(REFRESH_KEY)) {
      if (await tryRefresh()) d = await gql<{ me: User | null }>(ME);
    }

    if (!d.me) clearTokens();
    setUser(d.me);
    syncVenue(d.me);
  }, [syncVenue]);

  useEffect(() => {
    refreshMe()
      .catch((e) => {
        // A rejected session is stale — drop the token so it stops being sent.
        // An unreachable server says nothing about the session, so keep it and
        // let the next request retry.
        if (!(e instanceof ConnectionError)) localStorage.removeItem('blastek-token');
        setUser(null);
      })
      .finally(() => setLoading(false));
  }, [refreshMe]);

  const accept = (payload: { token: string; refreshToken?: string; user: User }) => {
    localStorage.setItem(TOKEN_KEY, payload.token);
    if (payload.refreshToken) localStorage.setItem(REFRESH_KEY, payload.refreshToken);
    setUser(payload.user);
    syncVenue(payload.user);
    return payload.user;
  };

  const login = async (email: string, password: string) => {
    const d = await gql<{ login: { token: string; user: User } }>(
      `mutation($email: String!, $password: String!) {
        login(email: $email, password: $password) { ${AUTH_FIELDS} } }`,
      { email, password });
    return accept(d.login);
  };

  const signUp = async (input: { email: string; password: string; firstName: string;
    lastName?: string; phone?: string; businessName?: string }) => {
    const d = await gql<{ signUp: { token: string; user: User } }>(
      `mutation($email: String!, $password: String!, $firstName: String!, $lastName: String,
        $phone: String, $businessName: String) {
        signUp(email: $email, password: $password, firstName: $firstName, lastName: $lastName,
          phone: $phone, businessName: $businessName) { ${AUTH_FIELDS} } }`,
      input);
    return accept(d.signUp);
  };

  const requestOtp = async (phone: string) => {
    const d = await gql<{ requestOtp: OtpRequest }>(
      `mutation($phone: String!) {
        requestOtp(phone: $phone) { phone expiresAt resendAfter } }`,
      { phone });
    return d.requestOtp;
  };

  const verifyOtp = async (phone: string, code: string) => {
    const d = await gql<{ verifyOtp: { token: string; refreshToken: string; user: User } }>(
      `mutation($phone: String!, $code: String!) {
        verifyOtp(phone: $phone, code: $code) { ${AUTH_FIELDS} } }`,
      { phone, code });
    return accept(d.verifyOtp);
  };

  const completeProfile = async (firstName: string, lastName?: string) => {
    const d = await gql<{ completeProfile: User }>(
      `mutation($firstName: String!, $lastName: String) {
        completeProfile(firstName: $firstName, lastName: $lastName) { ${USER_FIELDS} } }`,
      { firstName, lastName });
    setUser(d.completeProfile);
    return d.completeProfile;
  };

  const selectVenue = (slug: string) => {
    setActiveVenue(slug);
    setActive(slug);
  };

  // Tells the server first: a session that is only forgotten locally is still a
  // live credential, and revoking it is the whole point of server-side sessions.
  const logout = async () => {
    try {
      await gql('mutation { logout }');
    } catch {
      // Already invalid, or offline. Either way the local state must still go.
    }
    clearTokens();
    setActiveVenue(null);
    setActive(null);
    setUser(null);
  };

  return (
    <Ctx.Provider value={{ user, loading, memberships: user?.venues ?? [], activeVenue,
      selectVenue, login, signUp, requestOtp, verifyOtp, completeProfile, logout, refreshMe }}>
      {children}
    </Ctx.Provider>
  );
}

function clearTokens() {
  localStorage.removeItem(TOKEN_KEY);
  localStorage.removeItem(REFRESH_KEY);
}

/** Exchanges the refresh token for a new pair. Returns whether it worked. */
async function tryRefresh(): Promise<boolean> {
  const refreshToken = localStorage.getItem(REFRESH_KEY);
  if (!refreshToken) return false;

  try {
    const d = await gql<{ refreshSession: { token: string; refreshToken: string } }>(
      `mutation($refreshToken: String!) {
        refreshSession(refreshToken: $refreshToken) { token refreshToken } }`,
      { refreshToken });

    localStorage.setItem(TOKEN_KEY, d.refreshSession.token);
    localStorage.setItem(REFRESH_KEY, d.refreshSession.refreshToken);
    return true;
  } catch {
    // Expired, or revoked because the server saw the token reused. Both mean
    // the same thing here: this device has to sign in again.
    clearTokens();
    return false;
  }
}
