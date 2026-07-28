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
  email: string;
  role: 'customer' | 'admin';
  firstName: string;
  lastName: string;
  phone: string;
  venues: VenueMembership[];
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
  logout: () => void;
  refreshMe: () => Promise<void>;
}

const Ctx = createContext<AuthCtx>(null!);
export const useAuth = () => useContext(Ctx);

const USER_FIELDS = `id email role firstName lastName phone
  venues { id role venue { id slug name city status } }`;

const ME = `{ me { ${USER_FIELDS} } }`;

const AUTH_FIELDS = `token user { ${USER_FIELDS} }`;

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
    if (!localStorage.getItem('blastek-token')) { setUser(null); return; }
    const d = await gql<{ me: User | null }>(ME);
    if (!d.me) localStorage.removeItem('blastek-token');
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

  const accept = (payload: { token: string; user: User }) => {
    localStorage.setItem('blastek-token', payload.token);
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

  const selectVenue = (slug: string) => {
    setActiveVenue(slug);
    setActive(slug);
  };

  const logout = () => {
    localStorage.removeItem('blastek-token');
    setActiveVenue(null);
    setActive(null);
    setUser(null);
  };

  return (
    <Ctx.Provider value={{ user, loading, memberships: user?.venues ?? [], activeVenue,
      selectVenue, login, signUp, logout, refreshMe }}>
      {children}
    </Ctx.Provider>
  );
}
