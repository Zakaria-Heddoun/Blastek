// Minimal GraphQL client over fetch — Vite proxies /api to the Phoenix server.

// Thrown when the server never gave a usable answer: offline, 5xx, or a body
// that isn't GraphQL. In all three cases the request's fate is unknown, as
// opposed to a request the server understood and rejected.
export class ConnectionError extends Error {}

interface GqlResponse<T> {
  data?: T;
  errors?: { message: string }[];
}

// Which venue dashboard requests act on. The server only honours it when the
// signed-in user is a member of that venue — it selects among their own
// memberships, it does not grant access.
const VENUE_KEY = 'blastek-venue';

export const getActiveVenue = () => localStorage.getItem(VENUE_KEY);

export function setActiveVenue(slug: string | null) {
  if (slug) localStorage.setItem(VENUE_KEY, slug);
  else localStorage.removeItem(VENUE_KEY);
}

export async function gql<T>(query: string, variables: Record<string, unknown> = {}): Promise<T> {
  const token = localStorage.getItem('blastek-token');
  const venue = getActiveVenue();
  let res: Response;
  try {
    res = await fetch('/api/graphql', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        ...(token ? { Authorization: `Bearer ${token}` } : {}),
        ...(venue ? { 'X-Venue-Slug': venue } : {}),
      },
      body: JSON.stringify({ query, variables }),
    });
  } catch {
    throw new ConnectionError('Could not reach the server');
  }

  const json: GqlResponse<T> | null = await res.json().catch(() => null);
  if (json?.errors?.length) throw new Error(json.errors.map((e) => e.message).join('; '));
  if (res.status >= 500) throw new ConnectionError(`The server is unavailable (${res.status})`);
  if (!res.ok) throw new Error(`Request failed (${res.status})`);
  if (json?.data == null) throw new ConnectionError('The server returned a malformed response');
  return json.data;
}
