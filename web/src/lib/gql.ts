// Minimal GraphQL client over fetch — Vite proxies /api to the Phoenix server.
import i18n from './i18n';

// Thrown when the server never gave a usable answer: offline, 5xx, or a body
// that isn't GraphQL. In all three cases the request's fate is unknown, as
// opposed to a request the server understood and rejected.
export class ConnectionError extends Error {}

export interface GqlErrorDetail {
  message: string;
  /** Machine-readable kind: validation | not_found | forbidden | conflict | … */
  code?: string;
  /** Set on validation errors — the input field that failed, camelCased. */
  field?: string;
}

/**
 * A request the server understood and rejected. Carries the structured details
 * so a form can put each message next to the input that caused it, instead of
 * dumping one concatenated string above the form.
 */
export class GqlError extends Error {
  readonly details: GqlErrorDetail[];

  constructor(details: GqlErrorDetail[]) {
    super(details.map((d) => d.message).join('; '));
    this.name = 'GqlError';
    this.details = details;
  }

  get code() { return this.details[0]?.code; }

  /** Field name → first message for that field. */
  get fieldErrors(): Record<string, string> {
    const out: Record<string, string> = {};
    for (const d of this.details) {
      if (d.field && !(d.field in out)) out[d.field] = d.message;
    }
    return out;
  }
}

interface GqlResponse<T> {
  data?: T;
  errors?: GqlErrorDetail[];
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
        // Which language to resolve owner-written content in — service names,
        // taglines. The server prefers a signed-in user's saved choice over
        // this, so it matters most for visitors who have not signed in.
        'Accept-Language': i18n.resolvedLanguage ?? 'fr',
        ...(token ? { Authorization: `Bearer ${token}` } : {}),
        ...(venue ? { 'X-Venue-Slug': venue } : {}),
      },
      body: JSON.stringify({ query, variables }),
    });
  } catch {
    throw new ConnectionError(i18n.t('errors.offline'));
  }

  const json: GqlResponse<T> | null = await res.json().catch(() => null);
  if (json?.errors?.length) throw new GqlError(json.errors);
  if (res.status === 429) {
    throw new GqlError([{ message: i18n.t('errors.rateLimited'), code: 'rate_limited' }]);
  }
  if (res.status >= 500) throw new ConnectionError(`The server is unavailable (${res.status})`);
  if (!res.ok) throw new Error(`Request failed (${res.status})`);
  if (json?.data == null) throw new ConnectionError(i18n.t('errors.malformed'));
  return json.data;
}
