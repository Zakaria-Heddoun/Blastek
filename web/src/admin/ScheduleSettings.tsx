// Opening hours, seasonal schedules and closures (E5-T5 / F0.4).
//
// Three things that all answer "when are you open?", kept together because an
// owner setting up Ramadan hours and an owner closing for Eid are the same
// person on the same afternoon.
import { useCallback, useEffect, useState } from 'react';
import { useTranslation } from 'react-i18next';
import type { TFunction } from 'i18next';
import { gql } from '../lib/gql';
import { useToast } from '../components/ui';
import { Icon } from '../lib/icons';
import { fmtDateLong, weekdaysShort } from '../lib/format';

interface HourDay {
  weekday: number;
  working: boolean;
  startMin: number;
  endMin: number;
}

interface HourTemplate {
  id: string;
  name: string;
  active: boolean;
  days: HourDay[];
}

/** What the venue keeps this week; `open` is null on a day nobody works. */
interface VenueDay {
  weekday: number;
  open: number | null;
  close: number | null;
}

interface Closure {
  id: string;
  date: string;
  endDate: string | null;
  startMin: number | null;
  endMin: number | null;
  reason: string;
}

interface Conflict {
  id: string;
  date: string;
  startMin: number;
  client: { firstName: string; lastName: string; phone: string };
  service: { name: string };
  staff: { name: string };
}

const LOAD = `{
  venueHourTemplates { id name active days { weekday working startMin endMin } }
  venueWeek { weekday open close }
  venueClosures { id date endDate startMin endMin reason }
}`;

const SAVE_TEMPLATE = `mutation($name: String!, $days: [HourDayInput!]!) {
  saveHourTemplate(name: $name, days: $days) { id name }
}`;

const SET_TEMPLATE = `mutation($name: String!) { setHourTemplate(name: $name) { id name active } }`;

const CONFLICTS = `query($date: Date!, $endDate: Date, $startMin: Int, $endMin: Int) {
  closureConflicts(date: $date, endDate: $endDate, startMin: $startMin, endMin: $endMin) {
    id date startMin
    client { firstName lastName phone }
    service { name }
    staff { name }
  }
}`;

const CREATE_CLOSURE = `mutation($date: Date!, $endDate: Date, $startMin: Int, $endMin: Int,
  $reason: String) {
  createClosure(date: $date, endDate: $endDate, startMin: $startMin, endMin: $endMin,
    reason: $reason) { id }
}`;

const DELETE_CLOSURE = `mutation($id: ID!) { deleteClosure(id: $id) { id } }`;

/**
 * The venue's current week as an editable draft.
 *
 * Falls back to a plain 09:00–18:00 week only for the days it has nothing for,
 * so a brand-new venue still gets sensible defaults.
 */
const weekAsDraft = (week: VenueDay[]): HourDay[] =>
  emptyWeek().map((blank) => {
    const day = week.find((d) => d.weekday === blank.weekday);
    if (!day || day.open === null || day.close === null) {
      return { ...blank, working: day ? false : blank.working };
    }
    return { weekday: blank.weekday, working: true, startMin: day.open, endMin: day.close };
  });

const emptyWeek = (): HourDay[] =>
  [...Array(7)].map((_, weekday) => ({
    weekday,
    working: weekday !== 0,
    startMin: 540,
    endMin: 1080,
  }));

/** 1470 is 00:30 the next morning — a Ramadan evening, not a bug. */
export function fmtMinutes(min: number) {
  const wrapped = min % 1440;
  const h = Math.floor(wrapped / 60);
  const m = wrapped % 60;
  const label = `${String(h).padStart(2, '0')}:${String(m).padStart(2, '0')}`;
  return min >= 1440 ? `${label}⁺¹` : label;
}

// Quarter-hour steps to 06:00 the following morning, so a shift can legitimately
// end after midnight.
const TIME_OPTIONS = [...Array((1440 + 360) / 15 + 1)].map((_, i) => i * 15);

export default function ScheduleSettings() {
  const { t } = useTranslation();
  const toast = useToast();
  // Built once per render rather than once per cell — see `lib/format.ts`.
  const weekdays = weekdaysShort();

  const [templates, setTemplates] = useState<HourTemplate[] | null>(null);
  const [week, setWeek] = useState<VenueDay[]>([]);
  const [closures, setClosures] = useState<Closure[]>([]);
  const [editing, setEditing] = useState<string | null>(null);
  const [draft, setDraft] = useState<HourDay[]>(emptyWeek());
  const [busy, setBusy] = useState(false);

  const load = useCallback(async () => {
    try {
      const d = await gql<{
        venueHourTemplates: HourTemplate[];
        venueWeek: VenueDay[];
        venueClosures: Closure[];
      }>(LOAD);
      setTemplates(d.venueHourTemplates ?? []);
      setWeek(d.venueWeek ?? []);
      setClosures(d.venueClosures ?? []);
    } catch (e) {
      toast((e as Error).message, true);
      setTemplates([]);
    }
  }, [toast]);

  useEffect(() => {
    load();
  }, [load]);

  const act = async (query: string, variables: Record<string, unknown>, done: string) => {
    if (busy) return false;
    setBusy(true);
    try {
      await gql(query, variables);
      toast(done);
      await load();
      return true;
    } catch (e) {
      toast((e as Error).message, true);
      return false;
    } finally {
      setBusy(false);
    }
  };

  const startEditing = (name: string) => {
    const template = templates?.find((t) => t.name === name);

    // A venue that predates templates has no saved grid, but it does keep
    // hours. Opening the editor on a blank week would invite the owner to
    // overwrite them with 09:00–18:00 without ever being shown what they were.
    setDraft(
      template?.days?.length ? template.days.map((d) => ({ ...d })) : weekAsDraft(week),
    );
    setEditing(name);
  };

  const setDay = (weekday: number, patch: Partial<HourDay>) =>
    setDraft((week) => week.map((d) => (d.weekday === weekday ? { ...d, ...patch } : d)));

  const saveDraft = async () => {
    const ok = await act(
      SAVE_TEMPLATE,
      { name: editing, days: draft.map(({ weekday, working, startMin, endMin }) => ({ weekday, working, startMin, endMin })) },
      t('admin.schedule.saved'),
    );
    if (ok) setEditing(null);
  };

  const active = templates?.find((t) => t.active);

  return (
    <>
      <section className="card pad set-section">
        <div className="set-section-head">
          <h2>{t(`admin.schedule.title`)}</h2>
          <p className="mutetext">
            {t(`admin.schedule.templatesBody`)}
          </p>
        </div>

        {templates === null && <div className="empty">{t(`common.loading`)}</div>}

        {/* Whatever the venue actually keeps right now, template or not. It is
            what customers are shown, so it belongs above the editing controls
            rather than behind them. */}
        {templates !== null && (
          <div className="week-now">
            {week.map((day) => (
              <div key={day.weekday} className={`week-now-day${day.open === null ? ' is-closed' : ''}`}>
                <span className="fainttext">{weekdays[day.weekday]}</span>
                <b>
                  {day.open === null
                    ? 'Closed'
                    : `${fmtMinutes(day.open)} – ${fmtMinutes(day.close ?? 0)}`}
                </b>
              </div>
            ))}
          </div>
        )}

        <div className="tpl-rows">
          {templates?.map((template) => (
            <div key={template.id} className={`card pad tpl-row${template.active ? ' is-active' : ''}`}>
              <div className="grow">
                <b>{template.name}</b>
                {template.active && <span className="tpl-badge">{t(`admin.schedule.inUse`)}</span>}
                <div className="fainttext">{summarize(template.days, t)}</div>
              </div>

              <button className="btn btn-sm" disabled={busy} onClick={() => startEditing(template.name)}>
                {t(`common.edit`)}
              </button>

              {!template.active && (
                <button
                  className="btn btn-sm btn-primary"
                  disabled={busy}
                  onClick={() => act(SET_TEMPLATE, { name: template.name }, `Switched to ${template.name}`)}
                >
                  {t(`admin.schedule.useThis`)}
                </button>
              )}
            </div>
          ))}
        </div>

        <div className="tpl-add">
          {['default', 'ramadan'].map((name) =>
            templates?.some((t) => t.name === name) ? null : (
              <button key={name} className="btn btn-sm" onClick={() => startEditing(name)}>
                <Icon name="plus" size={14} /> Set up {name} hours
              </button>
            ),
          )}
        </div>

        {editing && (
          <div className="hours-grid">
            <h3>{editing} hours</h3>
            {draft.map((day) => (
              <div key={day.weekday} className="hours-row">
                <label className="hours-day">
                  <input
                    type="checkbox"
                    checked={day.working}
                    onChange={(e) => setDay(day.weekday, { working: e.target.checked })}
                  />
                  {weekdays[day.weekday]}
                </label>

                <select
                  aria-label={t('common.opensAria', { day: weekdays[day.weekday] })}
                  disabled={!day.working}
                  value={day.startMin}
                  onChange={(e) => setDay(day.weekday, { startMin: Number(e.target.value) })}
                >
                  {TIME_OPTIONS.map((m) => (
                    <option key={m} value={m}>{fmtMinutes(m)}</option>
                  ))}
                </select>

                <span className="fainttext">to</span>

                <select
                  aria-label={t('common.closesAria', { day: weekdays[day.weekday] })}
                  disabled={!day.working}
                  value={day.endMin}
                  onChange={(e) => setDay(day.weekday, { endMin: Number(e.target.value) })}
                >
                  {TIME_OPTIONS.map((m) => (
                    <option key={m} value={m}>{fmtMinutes(m)}</option>
                  ))}
                </select>

                {day.working && day.endMin > 1440 && (
                  <span className="fainttext">closes after midnight</span>
                )}
              </div>
            ))}

            <div className="modal-actions">
              <button className="btn" onClick={() => setEditing(null)}>{t(`common.cancel`)}</button>
              <button className="btn btn-primary" disabled={busy} onClick={saveDraft}>
                Save {editing} hours
              </button>
            </div>
          </div>
        )}
      </section>

      <ClosuresSection
        closures={closures}
        active={active?.name}
        busy={busy}
        onCreate={(vars) => act(CREATE_CLOSURE, vars, t('admin.schedule.closureAdded'))}
        onDelete={(id) => act(DELETE_CLOSURE, { id }, t('admin.schedule.closureRemoved'))}
      />
    </>
  );
}

function ClosuresSection({
  closures,
  busy,
  onCreate,
  onDelete,
}: {
  closures: Closure[];
  active?: string;
  busy: boolean;
  onCreate: (vars: Record<string, unknown>) => Promise<boolean>;
  onDelete: (id: string) => void;
}) {
  const { t } = useTranslation();
  const [date, setDate] = useState('');
  const [endDate, setEndDate] = useState('');
  const [wholeDay, setWholeDay] = useState(true);
  const [startMin, setStartMin] = useState(720);
  const [endMin, setEndMin] = useState(840);
  const [reason, setReason] = useState('');
  const [conflicts, setConflicts] = useState<Conflict[] | null>(null);
  const [checkError, setCheckError] = useState('');
  const [checking, setChecking] = useState(false);

  const vars = () => ({
    date,
    endDate: endDate || null,
    startMin: wholeDay ? null : startMin,
    endMin: wholeDay ? null : endMin,
    reason,
  });

  // A result belongs to the period it was asked about. Leaving "nothing is
  // booked" on screen while the owner edits the dates underneath it is the same
  // false reassurance as showing it when the check failed.
  const forget = <T,>(set: (value: T) => void) => (value: T) => {
    set(value);
    setConflicts(null);
    setCheckError('');
  };

  // Checked before creating, never after. F0.4 is explicit that bookings inside
  // a new closure are shown to the owner to act on and never silently
  // cancelled — a salon closing for a funeral still has to telephone the four
  // people booked that afternoon.
  const check = async () => {
    if (!date) return;
    setChecking(true);
    setCheckError('');
    try {
      const d = await gql<{ closureConflicts: Conflict[] }>(CONFLICTS, vars());
      setConflicts(d.closureConflicts ?? []);
    } catch (e) {
      // Emphatically not `setConflicts([])`. A failed check rendered as
      // "nothing is booked in that period" is the one outcome this feature
      // exists to prevent: the owner shuts the day on that reassurance and
      // finds out from the customers standing outside.
      setConflicts(null);
      setCheckError((e as Error).message);
    } finally {
      setChecking(false);
    }
  };

  const create = async () => {
    if (await onCreate(vars())) {
      setDate('');
      setEndDate('');
      setReason('');
      setConflicts(null);
    }
  };

  return (
    <section className="card pad set-section">
      <div className="set-section-head">
        <h2>{t(`admin.schedule.closuresTitle`)}</h2>
        <p className="mutetext">
          {t(`admin.schedule.closuresBody`)}
        </p>
      </div>

      <div className="closure-form">
        <label>
          {t(`admin.schedule.firstDay`)}
          <input type="date" value={date} onChange={(e) => forget(setDate)(e.target.value)} />
        </label>

        <label>
          {t(`admin.schedule.lastDay`)}
          <input type="date" value={endDate} onChange={(e) => forget(setEndDate)(e.target.value)} />
        </label>

        <label className="closure-check">
          <input
            type="checkbox"
            checked={wholeDay}
            onChange={(e) => forget(setWholeDay)(e.target.checked)}
          />
          {t(`admin.schedule.closedAllDay`)}
        </label>

        {!wholeDay && (
          <div className="closure-window">
            <select value={startMin} onChange={(e) => forget(setStartMin)(Number(e.target.value))}
              aria-label={t(`admin.schedule.closedFrom`)}>
              {TIME_OPTIONS.map((m) => <option key={m} value={m}>{fmtMinutes(m)}</option>)}
            </select>
            <span className="fainttext">to</span>
            <select value={endMin} onChange={(e) => forget(setEndMin)(Number(e.target.value))}
              aria-label={t(`admin.schedule.closedUntil`)}>
              {TIME_OPTIONS.map((m) => <option key={m} value={m}>{fmtMinutes(m)}</option>)}
            </select>
          </div>
        )}

        <label>
          {t(`admin.schedule.reason`)}
          <input
            placeholder={t(`admin.schedule.reasonPlaceholder`)}
            value={reason}
            onChange={(e) => setReason(e.target.value)}
          />
        </label>

        <div className="modal-actions">
          <button className="btn btn-sm" disabled={!date || checking} onClick={check}>
            {checking ? 'Checking…' : t('admin.schedule.checkBookings')}
          </button>
          <button className="btn btn-primary btn-sm" disabled={!date || busy} onClick={create}>
            {t(`admin.schedule.addClosure`)}
          </button>
        </div>
      </div>

      {checkError && (
        <div className="closure-conflicts has-conflicts">
          <b>{t(`admin.schedule.checkFailed`)}</b>
          <p className="fainttext">
            {checkError} — try again before closing the day, rather than assuming it is empty.
          </p>
        </div>
      )}

      {conflicts !== null && (
        <div className={`closure-conflicts${conflicts.length ? ' has-conflicts' : ''}`}>
          {conflicts.length === 0 ? (
            <span className="fainttext">{t(`admin.schedule.nothingBooked`)}</span>
          ) : (
            <>
              <b>
                {conflicts.length} appointment{conflicts.length === 1 ? '' : 's'} would need moving
              </b>
              <p className="fainttext">
                {t(`admin.schedule.conflictsHint`)}
              </p>
              <ul>
                {conflicts.map((c) => (
                  <li key={c.id}>
                    {fmtDateLong(c.date)} {fmtMinutes(c.startMin)} · {c.client.firstName}{' '}
                    {c.client.lastName} · {c.service.name} with {c.staff.name}
                    {c.client.phone && <span className="fainttext"> · {c.client.phone}</span>}
                  </li>
                ))}
              </ul>
            </>
          )}
        </div>
      )}

      {closures.length === 0 ? (
        <div className="empty">{t(`admin.schedule.noClosures`)}</div>
      ) : (
        <div className="closure-rows">
          {closures.map((closure) => (
            <div key={closure.id} className="card pad closure-row">
              <div className="grow">
                <b>{describeClosure(closure)}</b>
                {closure.reason && <div className="fainttext">{closure.reason}</div>}
              </div>
              <button className="btn btn-sm btn-danger" disabled={busy}
                onClick={() => onDelete(closure.id)}>
                {t(`common.remove`)}
              </button>
            </div>
          ))}
        </div>
      )}
    </section>
  );
}

function describeClosure(closure: Closure) {
  const span = closure.endDate && closure.endDate !== closure.date
    ? `${fmtDateLong(closure.date)} – ${fmtDateLong(closure.endDate)}`
    : fmtDateLong(closure.date);

  if (closure.startMin == null || closure.endMin == null) return span;
  return `${span} · ${fmtMinutes(closure.startMin)}–${fmtMinutes(closure.endMin)}`;
}

function summarize(days: HourDay[], t: TFunction) {
  const working = (days ?? []).filter((d) => d.working);
  if (working.length === 0) return t('admin.schedule.closedAllWeek');

  const sample = working[0];
  const uniform = working.every((d) => d.startMin === sample.startMin && d.endMin === sample.endMin);

  // The point of the summary is telling two schedules apart, and "varies by
  // day" does not: a Ramadan evening and a winter morning read identically.
  // The outer span always distinguishes them.
  const times = uniform
    ? `${fmtMinutes(sample.startMin)}–${fmtMinutes(sample.endMin)}`
    : `${fmtMinutes(Math.min(...working.map((d) => d.startMin)))}–` +
      `${fmtMinutes(Math.max(...working.map((d) => d.endMin)))}, varying by day`;

  const weekdays = weekdaysShort();
  return `${working.map((d) => weekdays[d.weekday]).join(', ')} · ${times}`;
}
