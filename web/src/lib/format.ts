// Blastek content conventions: MAD currency, 24h time in the dashboard,
// 12h in customer-facing strings, "Tue, 12 May" dates.
//
// ## Localized through `Intl`, with one deliberate override (E7 / F0.11)
//
// Weekday and month names come from the browser rather than from the
// translation files: the data is already there, correct, and complete for every
// locale, and a hand-written list of twelve Arabic month names is twelve
// chances to be wrong.
//
// The override is **digits**. `Intl` renders Arabic locales with Arabic-Indic
// numerals (١٢:٣٠) by default, and Morocco does not use them — prices, times
// and phone numbers are written in Western digits throughout the Maghreb. The
// `-u-nu-latn` extension asks for exactly that while keeping Arabic words, and
// F0.11 calls it out by name.
import i18n from './i18n';

export const pad2 = (n: number) => String(n).padStart(2, '0');

/**
 * The BCP-47 tag to hand `Intl`, pinned to Western digits.
 *
 * Not exported as a constant because the language changes at runtime and a
 * constant would capture whichever one happened to be active at import time.
 */
const intlLocale = () => {
  const lng = i18n.resolvedLanguage ?? 'fr';
  // Region matters for date order and the decimal separator; Morocco for the
  // two local languages, France for French, and en-GB rather than en-US so a
  // date reads 12 May and not May 12.
  const base = lng === 'ar' ? 'ar-MA' : lng === 'en' ? 'en-GB' : 'fr-MA';
  return `${base}-u-nu-latn`;
};

/**
 * Formats integer centimes as MAD. Money crosses the API as centimes so it
 * never passes through a float — display is the only place it becomes a
 * decimal. Whole dirhams drop the ".00", which is how prices are written here.
 */
export const fmtMAD = (cents: number) => {
  const mad = (cents ?? 0) / 100;
  const digits = Number.isInteger(mad) ? 0 : 2;
  const amount = mad.toLocaleString(intlLocale(), {
    minimumFractionDigits: digits,
    maximumFractionDigits: digits,
  });
  // "MAD" rather than the currency style's "DH"/"د.م.": the abbreviation is
  // what Moroccan price lists actually print, in all three languages.
  return `${amount} ${i18n.t('common.currency')}`;
};

/** Centimes from a MAD amount typed by a human ("249.50" → 24950). */
export const madToCents = (mad: number | string) =>
  Math.round(Number(mad || 0) * 100);

/** MAD as a plain number, for prefilling numeric inputs. */
export const centsToMad = (cents: number) => (cents ?? 0) / 100;

export const fmtTime = (min: number, clock12 = false) => {
  const h = Math.floor(min / 60), m = min % 60;
  if (!clock12) return `${pad2(h)}:${pad2(m)}`;
  // Built from a real Date so AM/PM is the locale's own marker (ص/م in Arabic)
  // rather than a Latin string glued onto an Arabic sentence.
  const d = new Date(2000, 0, 1, h, m);
  return d.toLocaleTimeString(intlLocale(), { hour: 'numeric', minute: '2-digit', hour12: true });
};

export const fmtDur = (min: number) =>
  min >= 60
    ? `${Math.floor(min / 60)}${i18n.t('common.hourShort')}${
        min % 60 ? ' ' + (min % 60) + i18n.t('common.minShort') : ''
      }`
    : `${min}${i18n.t('common.minShort')}`;

export const todayStr = () => {
  const d = new Date();
  return `${d.getFullYear()}-${pad2(d.getMonth() + 1)}-${pad2(d.getDate())}`;
};

export const addDays = (ds: string, n: number) => {
  const d = new Date(ds + 'T12:00:00');
  d.setDate(d.getDate() + n);
  return `${d.getFullYear()}-${pad2(d.getMonth() + 1)}-${pad2(d.getDate())}`;
};

// Midday, so a date string never lands on the wrong day through a DST shift.
const atNoon = (ds: string) => new Date(ds.slice(0, 10) + 'T12:00:00');

// Weekday 0 = Sunday, matching `Date.getDay()` and the API's `weekday` column.
// 2023-01-01 was a Sunday, which makes this table trivially checkable.
const WEEKDAY_SAMPLES = [1, 2, 3, 4, 5, 6, 7].map((day) => new Date(2023, 0, day));

/**
 * Cached per locale and width.
 *
 * Constructing an `Intl.DateTimeFormat` is expensive, and these are read inside
 * render loops — the schedule editor asks three times per weekday row, which
 * without a cache is 147 formatter constructions every time it re-renders.
 * The key includes the locale, so switching language still rebuilds them.
 */
const weekdayCache = new Map<string, string[]>();

const weekdayNames = (width: 'short' | 'long') => {
  const locale = intlLocale();
  const key = `${locale}:${width}`;
  const cached = weekdayCache.get(key);
  if (cached) return cached;

  const names = WEEKDAY_SAMPLES.map((d) => d.toLocaleDateString(locale, { weekday: width }));
  weekdayCache.set(key, names);
  return names;
};

/** Weekday names in the active language: `['dim.', 'lun.', …]`. */
export const weekdaysShort = () => weekdayNames('short');

/** Weekday names in full: `['dimanche', 'lundi', …]`. */
export const weekdaysFull = () => weekdayNames('long');

export const fmtDateShort = (ds: string) =>
  atNoon(ds).toLocaleDateString(intlLocale(), { weekday: 'short', day: 'numeric', month: 'short' });

export const fmtDateLong = (ds: string) =>
  atNoon(ds).toLocaleDateString(intlLocale(), { weekday: 'long', day: 'numeric', month: 'long' });

/** Month and year, for a calendar header: "août 2026". */
export const fmtMonthYear = (ds: string) =>
  atNoon(ds).toLocaleDateString(intlLocale(), { month: 'long', year: 'numeric' });

export const mondayOf = (ds: string) => {
  const d = new Date(ds + 'T12:00:00');
  return addDays(ds, -((d.getDay() + 6) % 7));
};

/** Appointment status as a person reads it. */
export const statusLabel = (status: string) =>
  i18n.t(`status.${status}`, { defaultValue: status });

export const initials = (name: string) =>
  name.split(/\s+/).map((w) => w[0]).slice(0, 2).join('').toUpperCase();
