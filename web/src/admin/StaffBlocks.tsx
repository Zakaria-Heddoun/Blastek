// Blocking out a staff member's time, from the calendar (E9-T2 / F0.7).
//
// Kept out of CalendarPage, which is already the largest screen in the
// dashboard: these two components are only reachable from an empty-slot click
// and share nothing with the appointment flow but the grid they sit on.
import { useEffect, useState } from 'react';
import { useTranslation } from 'react-i18next';
import { gql } from '../lib/gql';
import type { Appointment } from '../lib/types';
import { useAppData } from './AdminLayout';
import { Modal, useToast } from '../components/ui';
import { fmtDateLong, fmtTime } from '../lib/format';

/** One staff member's unavailable time. */
export interface StaffBlock {
  id: string;
  staffId: string;
  kind: 'time_off' | 'break' | 'blocked';
  date: string;
  endDate: string | null;
  startMin: number | null;
  endMin: number | null;
  weekly: boolean;
  weekday: number | null;
  note: string;
}

export const BLOCK_FIELDS = `id staffId kind date endDate startMin endMin weekly weekday note`;

/**
 * Block bands for one staff member on one date, clipped to the visible hours.
 *
 * The weekly-repeat rule is applied here as well as server-side, and on
 * purpose: the calendar draws days the availability engine was never asked
 * about, so it has to expand the repeat itself or a recurring break would be
 * invisible on every day but the one the row names.
 */
export function blockBands(
  blocks: StaffBlock[],
  staffId: string | undefined,
  date: string,
  dayStart: number,
  dayEnd: number,
) {
  if (!staffId) return [];
  const weekday = new Date(date + 'T12:00:00').getDay();

  return blocks
    .filter((b) => b.staffId === staffId)
    .filter((b) =>
      b.weekly
        ? b.weekday === weekday && date >= b.date
        : date >= b.date && date <= (b.endDate || b.date),
    )
    .map((b) => ({
      from: Math.max(b.startMin ?? 0, dayStart),
      to: Math.min(b.endMin ?? 24 * 60, dayEnd),
      kind: b.kind,
      note: b.note,
    }))
    .filter((band) => band.to > band.from);
}

/**
 * What the salon meant by clicking an empty slot.
 *
 * A popover rather than a modal: it is anchored to the minute that was
 * clicked, and a full-screen dialog would lose that context — which is the
 * only piece of information the click carried.
 */
export function SlotMenu({
  at,
  onClose,
  onAppointment,
  onBlock,
}: {
  at: { date: string; startMin: number; x: number; y: number };
  onClose: () => void;
  onAppointment: () => void;
  onBlock: () => void;
}) {
  const { t } = useTranslation();

  useEffect(() => {
    const dismiss = () => onClose();
    // Deferred: the click that opened this menu is still propagating, and
    // listening immediately closes it in the same tick it opens.
    const id = setTimeout(() => document.addEventListener('click', dismiss), 0);
    return () => {
      clearTimeout(id);
      document.removeEventListener('click', dismiss);
    };
  }, [onClose]);

  return (
    <div className="slot-menu" style={{ top: at.y, left: at.x }} onClick={(e) => e.stopPropagation()}>
      <div className="slot-menu-when">{fmtTime(at.startMin)}</div>
      <button onClick={onAppointment}>{t('admin.calendar.newAppointment')}</button>
      <button onClick={onBlock}>{t('admin.calendar.blockTime')}</button>
    </div>
  );
}

const timeOptions = (from = 480, to = 1185) => {
  const out: number[] = [];
  for (let m = from; m <= to; m += 15) out.push(m);
  return out;
};

const clientName = (a: Appointment) => `${a.client.firstName} ${a.client.lastName}`.trim();

/**
 * Blocking out time, with the conflicts shown before it is saved.
 *
 * F0.7: "creating a block over existing appointments prompts conflict list;
 * never silent". The conflicts are fetched as the form changes rather than on
 * submit, so the owner sees what they are about to break while they are still
 * deciding — not after.
 */
export function BlockModal({
  preset,
  onClose,
  onDone,
}: {
  preset: { staffId: string; date: string; startMin: number };
  onClose: () => void;
  onDone: () => void;
}) {
  const { t } = useTranslation();
  const { staff } = useAppData();
  const toast = useToast();

  const [f, setF] = useState({
    staffId: preset.staffId,
    kind: 'break' as StaffBlock['kind'],
    date: preset.date,
    endDate: '',
    startMin: preset.startMin,
    endMin: preset.startMin + 60,
    weekly: false,
    note: '',
  });
  const [conflicts, setConflicts] = useState<Appointment[]>([]);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState('');

  const wholeDay = f.kind === 'time_off';

  const variables = () => ({
    staffId: f.staffId,
    kind: f.kind,
    date: f.date,
    endDate: wholeDay && f.endDate ? f.endDate : null,
    startMin: wholeDay ? null : f.startMin,
    endMin: wholeDay ? null : f.endMin,
    weekly: wholeDay ? false : f.weekly,
  });

  useEffect(() => {
    let live = true;

    gql<{ staffBlockConflicts: Appointment[] }>(
      `mutation($staffId: ID!, $kind: String!, $date: Date!, $endDate: Date,
                $startMin: Int, $endMin: Int, $weekly: Boolean) {
        staffBlockConflicts(staffId: $staffId, kind: $kind, date: $date, endDate: $endDate,
          startMin: $startMin, endMin: $endMin, weekly: $weekly) {
          id date startMin endMin client { id firstName lastName } service { id name }
        }
      }`,
      variables(),
    )
      .then((d) => { if (live) setConflicts(d.staffBlockConflicts ?? []); })
      // A failed conflict check must not block the form: the owner can still
      // save, and the server is the one that decides.
      .catch(() => { if (live) setConflicts([]); });

    return () => { live = false; };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [f.staffId, f.kind, f.date, f.endDate, f.startMin, f.endMin, f.weekly]);

  const save = async () => {
    setBusy(true);
    setErr('');
    try {
      await gql(
        `mutation($staffId: ID!, $kind: String!, $date: Date!, $endDate: Date,
                  $startMin: Int, $endMin: Int, $weekly: Boolean, $note: String) {
          createStaffBlock(staffId: $staffId, kind: $kind, date: $date, endDate: $endDate,
            startMin: $startMin, endMin: $endMin, weekly: $weekly, note: $note) { id }
        }`,
        { ...variables(), note: f.note },
      );
      toast(t('admin.calendar.blockSaved'));
      onDone();
    } catch (e) {
      setErr((e as Error).message);
    } finally {
      setBusy(false);
    }
  };

  return (
    <Modal onClose={onClose}>
      <h2>{t('admin.calendar.blockTime')}</h2>

      <label>{t('admin.calendar.teamMember')}</label>
      <select value={f.staffId} onChange={(e) => setF({ ...f, staffId: e.target.value })}>
        {staff.filter((s) => s.active).map((s) => (
          <option key={s.id} value={s.id}>{s.name}</option>
        ))}
      </select>

      <label>{t('admin.calendar.blockKindLabel')}</label>
      <select value={f.kind} onChange={(e) => setF({ ...f, kind: e.target.value as StaffBlock['kind'] })}>
        <option value="break">{t('admin.calendar.blockKind.break')}</option>
        <option value="time_off">{t('admin.calendar.blockKind.time_off')}</option>
        <option value="blocked">{t('admin.calendar.blockKind.blocked')}</option>
      </select>

      <div className="grid2">
        <div>
          <label>{t('admin.schedule.firstDay')}</label>
          <input type="date" value={f.date} onChange={(e) => setF({ ...f, date: e.target.value })} />
        </div>
        {wholeDay && (
          <div>
            <label>{t('admin.schedule.lastDay')}</label>
            <input
              type="date"
              value={f.endDate}
              min={f.date}
              onChange={(e) => setF({ ...f, endDate: e.target.value })}
            />
          </div>
        )}
      </div>

      {!wholeDay && (
        <>
          <div className="grid2">
            <div>
              <label>{t('admin.schedule.closedFrom')}</label>
              <select value={f.startMin} onChange={(e) => setF({ ...f, startMin: Number(e.target.value) })}>
                {timeOptions().map((m) => <option key={m} value={m}>{fmtTime(m)}</option>)}
              </select>
            </div>
            <div>
              <label>{t('admin.schedule.closedUntil')}</label>
              <select value={f.endMin} onChange={(e) => setF({ ...f, endMin: Number(e.target.value) })}>
                {timeOptions().filter((m) => m > f.startMin).map((m) => (
                  <option key={m} value={m}>{fmtTime(m)}</option>
                ))}
              </select>
            </div>
          </div>

          <label className="check-inline">
            <input
              type="checkbox"
              className="toggle-switch"
              checked={f.weekly}
              onChange={(e) => setF({ ...f, weekly: e.target.checked })}
            />
            {t('admin.calendar.repeatWeekly')}
          </label>
        </>
      )}

      <label>{t('admin.schedule.reason')}</label>
      <input value={f.note} onChange={(e) => setF({ ...f, note: e.target.value })} />

      {conflicts.length > 0 && (
        <div className="closure-conflicts has-conflicts">
          <b>{t('admin.calendar.blockConflicts', { count: conflicts.length })}</b>
          <ul>
            {conflicts.slice(0, 8).map((a) => (
              <li key={a.id}>
                {fmtDateLong(a.date)} {fmtTime(a.startMin)} · {clientName(a)} · {a.service.name}
              </li>
            ))}
          </ul>
          <p className="fainttext">{t('admin.schedule.conflictsHint')}</p>
        </div>
      )}

      <div className="err">{err}</div>
      <div className="actions">
        <button className="btn" onClick={onClose}>{t('common.cancel')}</button>
        <button className="btn btn-primary" disabled={busy} onClick={save}>
          {busy ? t('common.saving') : t('common.save')}
        </button>
      </div>
    </Modal>
  );
}
