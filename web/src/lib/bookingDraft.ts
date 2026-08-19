import type { Slot } from './types';

const KEY = 'blastek-booking-draft';
const MAX_AGE_MS = 2 * 60 * 60 * 1000;

export interface BookingDraft {
  slug: string;
  services: string[];
  staffId: string;
  date: string;
  slot: Slot | null;
  notes: string;
  step: number;
  savedAt: number;
}

/**
 * Reads a short-lived draft for one venue.
 *
 * Session storage keeps it in the current tab through login and refreshes, but
 * does not leave booking details behind indefinitely on a shared device.
 */
export function loadBookingDraft(slug: string): BookingDraft | null {
  try {
    const parsed: unknown = JSON.parse(sessionStorage.getItem(KEY) ?? 'null');
    if (!isDraft(parsed) || Date.now() - parsed.savedAt > MAX_AGE_MS) {
      clearBookingDraft();
      return null;
    }
    if (parsed.slug !== slug) {
      clearBookingDraft();
      return null;
    }
    return parsed;
  } catch {
    clearBookingDraft();
    return null;
  }
}

export function saveBookingDraft(draft: Omit<BookingDraft, 'savedAt'>) {
  try {
    sessionStorage.setItem(KEY, JSON.stringify({ ...draft, savedAt: Date.now() }));
  } catch {
    // Storage can be unavailable in private browsing. The booking still works;
    // only navigation through authentication loses its draft in that case.
  }
}

export function clearBookingDraft() {
  try {
    sessionStorage.removeItem(KEY);
  } catch {
    // Nothing else can be done when storage is unavailable.
  }
}

function isDraft(value: unknown): value is BookingDraft {
  if (!value || typeof value !== 'object') return false;
  const draft = value as Partial<BookingDraft>;
  const slot = draft.slot;

  return (
    typeof draft.slug === 'string' &&
    Array.isArray(draft.services) &&
    draft.services.every((id) => typeof id === 'string') &&
    typeof draft.staffId === 'string' &&
    typeof draft.date === 'string' &&
    /^\d{4}-\d{2}-\d{2}$/.test(draft.date) &&
    typeof draft.notes === 'string' &&
    typeof draft.step === 'number' &&
    Number.isInteger(draft.step) &&
    draft.step >= 1 &&
    draft.step <= 4 &&
    typeof draft.savedAt === 'number' &&
    Number.isFinite(draft.savedAt) &&
    (slot === null ||
      (!!slot &&
        typeof slot.startMin === 'number' &&
        Number.isFinite(slot.startMin) &&
        typeof slot.staffId === 'string'))
  );
}
