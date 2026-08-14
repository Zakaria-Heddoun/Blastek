// Moving a booking from the account page (E9-T5 / F0.9).
//
// The customer already chose their services; this is only "when". So it shows
// the slot picker and nothing else — the venue, the treatments and the person
// are what they were, and re-asking would turn a thirty-second change into the
// booking flow again, which is the thing this exists to avoid.
import { useState } from 'react';
import { useTranslation } from 'react-i18next';
import { gql } from '../lib/gql';
import type { Appointment, Slot } from '../lib/types';
import { Modal, useToast } from '../components/ui';
import { fmtDateLong, fmtTime, todayStr } from '../lib/format';
import SlotPicker from './SlotPicker';

const RESCHEDULE = `mutation($ref: String!, $date: Date!, $startMin: Int!, $staffId: String) {
  rescheduleMyAppointment(bookingRef: $ref, date: $date, startMin: $startMin, staffId: $staffId) {
    bookingRef date startMin staffName
  }
}`;

export default function RescheduleModal({
  appointment,
  group,
  onClose,
  onDone,
}: {
  appointment: Appointment;
  /** Every appointment under the same reference — a booking moves as one. */
  group: Appointment[];
  onClose: () => void;
  onDone: () => void;
}) {
  const { t } = useTranslation();
  const toast = useToast();

  const [date, setDate] = useState(todayStr());
  const [slot, setSlot] = useState<Slot | null>(null);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState('');

  const serviceIds = group.map((a) => a.service.id);
  const slug = appointment.venue?.slug ?? '';

  const save = async () => {
    if (!slot) return;
    setBusy(true);
    setErr('');

    try {
      await gql(RESCHEDULE, {
        ref: appointment.bookingRef,
        date,
        startMin: slot.startMin,
        // Whoever is free. A customer moving to a different day often cannot
        // have the same person, and refusing for that reason turns a
        // reschedule into a cancellation.
        staffId: 'any',
      });
      toast(t('account.rescheduled'));
      onDone();
    } catch (e) {
      setErr((e as Error).message);
    } finally {
      setBusy(false);
    }
  };

  return (
    <Modal onClose={onClose}>
      <h2>{t('account.rescheduleTitle')}</h2>
      <p className="mutetext" style={{ marginTop: 0 }}>{t('account.rescheduleLead')}</p>

      <div className="fainttext" style={{ marginBottom: 14 }}>
        {group.map((a) => a.service.name).join(' · ')} — {fmtDateLong(appointment.date)},{' '}
        {fmtTime(appointment.startMin, true)}
      </div>

      <SlotPicker
        venueSlug={slug}
        serviceIds={serviceIds}
        date={date}
        onDate={setDate}
        selected={slot}
        onSelect={setSlot}
        emptyHint={t('account.pickAnotherDay')}
      />

      <div className="err">{err}</div>
      <div className="actions">
        <button className="btn" onClick={onClose}>{t('common.cancel')}</button>
        <button className="btn btn-primary" disabled={busy || !slot} onClick={save}>
          {busy ? t('common.saving') : t('account.reschedule')}
        </button>
      </div>
    </Modal>
  );
}
