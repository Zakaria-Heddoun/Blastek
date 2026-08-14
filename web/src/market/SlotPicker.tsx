// Picking a day and a time (E9-T5 / F0.9, extracted from BookingFlow step 3).
//
// Two screens need this and they are not the same screen: booking picks a slot
// for services chosen a moment ago, rescheduling picks one for services chosen
// last week. What they share is the hard part — a fortnight of dates, live
// availability for the selected one, and the three states that grid can be in
// (loading, empty, full). Duplicating that is how the two drift until one of
// them offers a slot the other knows is gone.
import { useEffect, useState } from 'react';
import { useTranslation } from 'react-i18next';
import { gql } from '../lib/gql';
import type { Slot } from '../lib/types';
import { addDays, fmtTime, todayStr, weekdaysShort } from '../lib/format';

const AVAILABILITY = `query($venue: String!, $ids: [ID!]!, $staff: String, $date: Date!) {
  availability(venueSlug: $venue, serviceIds: $ids, staffId: $staff, date: $date) {
    slots { startMin staffId }
  }
}`;

export default function SlotPicker({
  venueSlug,
  serviceIds,
  staffId = 'any',
  date,
  onDate,
  selected,
  onSelect,
  days = 14,
  emptyHint,
}: {
  venueSlug: string;
  serviceIds: string[];
  staffId?: string;
  date: string;
  onDate: (date: string) => void;
  selected: Slot | null;
  onSelect: (slot: Slot | null) => void;
  /** How far ahead the date strip runs. */
  days?: number;
  /** Shown when the chosen day has nothing, so each caller can say why. */
  emptyHint?: string;
}) {
  const { t } = useTranslation();
  const [slots, setSlots] = useState<Slot[] | null>(null);
  const weekdays = weekdaysShort();
  const strip = [...Array(days)].map((_, i) => addDays(todayStr(), i));

  // The effect keys on the *contents* of `serviceIds`, not the array. A caller
  // that builds the list inline — `group.map(a => a.service.id)` — hands over a
  // new array on every one of its own renders, so a reference dependency
  // refetched the whole grid each time the parent re-rendered: one wasted round
  // trip and a blank grid at the moment somebody is choosing a time. Fixing it
  // here rather than asking each caller to memoize, because forgetting is
  // silent and this is the component that knows it matters.
  const serviceKey = serviceIds.join(',');

  useEffect(() => {
    if (serviceIds.length === 0) return;

    let live = true;
    setSlots(null);

    gql<{ availability: { slots: Slot[] } }>(AVAILABILITY, {
      venue: venueSlug,
      ids: serviceIds,
      staff: staffId,
      date,
    })
      .then((d) => { if (live) setSlots(d.availability.slots); })
      // An empty grid rather than a broken screen: the customer can pick
      // another day, which is the only useful thing to do either way.
      .catch(() => { if (live) setSlots([]); });

    return () => { live = false; };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [venueSlug, serviceKey, staffId, date]);

  return (
    <>
      <div className="date-strip">
        {strip.map((d) => {
          const dt = new Date(d + 'T12:00:00');
          return (
            <div
              key={d}
              className={`date-pill ${d === date ? 'sel' : ''}`}
              onClick={() => { onDate(d); onSelect(null); }}
            >
              <small>{weekdays[dt.getDay()]}</small>{dt.getDate()}
            </div>
          );
        })}
      </div>

      {slots === null ? (
        <div className="empty">{t('flow.loadingAvailability')}</div>
      ) : slots.length === 0 ? (
        <div className="empty">{emptyHint ?? t('flow.noAvailability')}</div>
      ) : (
        <div className="slot-grid">
          {slots.map((s) => (
            <div
              key={s.startMin}
              className={`slot ${selected?.startMin === s.startMin ? 'sel' : ''}`}
              onClick={() => onSelect(s)}
            >
              {fmtTime(s.startMin, true)}
            </div>
          ))}
        </div>
      )}
    </>
  );
}
