// Calendar: day view (column per staff member) + week view (per staff),
// appointment create/detail/checkout flows.
import { useCallback, useEffect, useMemo, useState } from 'react';
import { gql } from '../lib/gql';
import { subscribe } from '../lib/live';
import type { Appointment, Client, Staff } from '../lib/types';
import { useAppData } from './AdminLayout';
import { Modal, StatusBadge, useToast } from '../components/ui';
import { Icon } from '../lib/icons';
import {
  addDays, fmtDateLong, fmtDateShort, fmtDur, fmtMAD, fmtTime,
  centsToMad, madToCents, mondayOf, todayStr, WEEKDAYS,
} from '../lib/format';

const DAY_START = 480, DAY_END = 1200;
const PX_MIN = 64 / 60;

export const APPT_FIELDS = `fragment ApptFields on Appointment {
  id bookingRef date startMin endMin status priceCents notes source
  client { id firstName lastName allergies }
  service { id name durationMin }
  staff { id name color }
}`;

const APPOINTMENT_CHANGED = `${APPT_FIELDS}
  subscription { appointmentChanged { ...ApptFields } }`;

const clientName = (a: Appointment) => `${a.client.firstName} ${a.client.lastName}`.trim();

function timeOptions(from = 480, to = 1185) {
  const out: number[] = [];
  for (let m = from; m <= to; m += 15) out.push(m);
  return out;
}

export default function CalendarPage() {
  const { staff } = useAppData();
  const toast = useToast();
  const active = staff.filter((s) => s.active);
  const [view, setView] = useState<'day' | 'week'>('day');
  const [date, setDate] = useState(todayStr());
  const [weekStaff, setWeekStaff] = useState(active[0]?.id ?? '');
  const [appts, setAppts] = useState<Appointment[]>([]);
  const [closures, setClosures] = useState<Closure[]>([]);
  const [createAt, setCreateAt] = useState<{ staffId: string; date: string; startMin: number } | null>(null);
  const [detail, setDetail] = useState<Appointment | null>(null);
  const [checkout, setCheckout] = useState<Appointment[] | null>(null);

  const monday = mondayOf(date);
  const from = view === 'day' ? date : monday;
  const to = view === 'day' ? date : addDays(monday, 6);

  const load = useCallback(async () => {
    const d = await gql<{ appointments: Appointment[]; venueClosures: Closure[] }>(
      `${APPT_FIELDS} query($from: Date!, $to: Date!) {
        appointments(from: $from, to: $to) { ...ApptFields }
        venueClosures(from: $from, to: $to) { id date endDate startMin endMin reason }
      }`,
      { from, to },
    );
    setAppts(d.appointments);
    setClosures(d.venueClosures ?? []);
  }, [from, to]);

  useEffect(() => { load(); }, [load]);

  // A booking made online lands on a calendar somebody is already looking at.
  // Without this the receptionist finds out by refreshing, which is how two
  // people get told the same slot is free (E6-T10, over E2-T4's subscription).
  useEffect(() => {
    let stop: (() => void) | undefined;

    subscribe<{ appointmentChanged: Appointment }>(APPOINTMENT_CHANGED, (data) => {
      const appointment = data.appointmentChanged;
      if (!appointment) return;

      // Only announce what a person did from outside this dashboard. Echoing
      // back the receptionist's own edit as a toast trains them to ignore it.
      if (appointment.source === 'online' && appointment.status !== 'cancelled') {
        toast(`New online booking — ${appointment.client?.firstName ?? 'a customer'} at ${fmtTime(appointment.startMin)}`);
      }

      // Reload rather than splice: the change may be a cancellation, a move, or
      // a checkout, and the query already knows how to answer "what is on this
      // day".
      load();
    }).then((subscription) => {
      stop = subscription.unsubscribe;
    });

    return () => stop?.();
  }, [load, toast]);

  const cols = useMemo(() => {
    if (view === 'day') {
      return active.map((st) => ({
        key: st.id, staff: st, date, clickable: false,
        header: <><span className="dot" style={{ background: st.color }} />{st.name}</>,
        appts: appts.filter((a) => a.staff.id === st.id && a.date === date),
      }));
    }
    const st = active.find((s) => s.id === weekStaff) ?? active[0];
    return [...Array(7)].map((_, i) => {
      const ds = addDays(monday, i);
      return {
        key: ds, staff: st, date: ds, clickable: true,
        header: <>{WEEKDAYS[new Date(ds + 'T12:00:00').getDay()]}<small>{ds.slice(8)}</small></>,
        appts: appts.filter((a) => a.staff.id === st.id && a.date === ds),
      };
    });
  }, [view, active, appts, date, weekStaff, monday]);

  const height = (DAY_END - DAY_START) * PX_MIN;
  const step = (dir: number) => setDate(addDays(date, view === 'day' ? dir : dir * 7));

  const openCheckout = (a: Appointment) => {
    const group = appts.filter((x) =>
      x.client.id === a.client.id && x.date === a.date &&
      !['completed', 'cancelled', 'no_show'].includes(x.status) &&
      (x.id === a.id || (a.bookingRef !== '' && x.bookingRef === a.bookingRef)));
    setDetail(null);
    setCheckout(group.length ? group : [a]);
  };

  return (
    <>
      <div className="page-head">
        <h1>Calendar</h1><div className="grow" />
        <button className="btn btn-primary" onClick={() => setCreateAt({ staffId: active[0].id, date, startMin: 600 })}>
          <Icon name="plus" size={16} /> New appointment
        </button>
      </div>
      <div className="card">
        <div className="cal-toolbar pad" style={{ paddingBottom: 12 }}>
          <button className="btn btn-sm" onClick={() => setDate(todayStr())}>Today</button>
          <button className="btn btn-sm" aria-label="Previous" onClick={() => step(-1)}><Icon name="left" size={16} /></button>
          <button className="btn btn-sm" aria-label="Next" onClick={() => step(1)}><Icon name="right" size={16} /></button>
          <div className="cal-date">
            {view === 'day' ? fmtDateLong(date) : `${fmtDateShort(monday)} – ${fmtDateShort(addDays(monday, 6))}`}
          </div>
          <div className="grow" />
          {view === 'week' && (
            <select value={weekStaff} onChange={(e) => setWeekStaff(e.target.value)}>
              {active.map((s) => <option key={s.id} value={s.id}>{s.name}</option>)}
            </select>
          )}
          <div className="chip-row">
            <button className={`chip ${view === 'day' ? 'active' : ''}`} onClick={() => setView('day')}>Day</button>
            <button className={`chip ${view === 'week' ? 'active' : ''}`} onClick={() => setView('week')}>Week</button>
          </div>
        </div>
        <div className="cal-wrap">
          <div className="cal-grid" style={{ gridTemplateColumns: `56px repeat(${cols.length}, 1fr)` }}>
            <div className="cal-head" />
            {cols.map((c) => (
              <div key={c.key} className={`cal-head ${c.clickable ? 'clickable' : ''}`}
                onClick={c.clickable ? () => { setView('day'); setDate(c.date); } : undefined}>
                <div>{c.header}</div>
              </div>
            ))}
            <div className="cal-gutter" style={{ height }}>
              {timeOptions(DAY_START, DAY_END).filter((m) => m % 60 === 0).map((m) => (
                <div key={m} className="tick" style={{ top: (m - DAY_START) * PX_MIN }}>{fmtTime(m).slice(0, 2)}</div>
              ))}
            </div>
            {cols.map((c) => {
              const wd = new Date(c.date + 'T12:00:00').getDay();
              const h = c.staff.hours.find((x) => x.weekday === wd);
              return (
                <div key={c.key} className="cal-col" style={{ height }}
                  onClick={(e) => {
                    const rect = e.currentTarget.getBoundingClientRect();
                    const min = DAY_START + Math.floor((e.clientY - rect.top) / PX_MIN / 15) * 15;
                    setCreateAt({ staffId: c.staff.id, date: c.date, startMin: min });
                  }}>
                  {timeOptions(DAY_START + 60, DAY_END - 15).filter((m) => m % 60 === 0).map((m) => (
                    <div key={m} className="hourline" style={{ top: (m - DAY_START) * PX_MIN }} />
                  ))}
                  {/* Closures sit above the off-hours shading and carry their
                      reason, so a blank Thursday reads as "Eid" rather than as
                      a scheduling mistake. */}
                  {closedBands(closures, c.date).map((band, i) => (
                    <div
                      key={`${c.key}-closure-${i}`}
                      className="closure-band"
                      title={band.reason || 'Closed'}
                      style={{
                        top: (band.from - DAY_START) * PX_MIN,
                        height: (band.to - band.from) * PX_MIN,
                      }}
                    >
                      <span>{band.reason || 'Closed'}</span>
                    </div>
                  ))}

                  {(!h || !h.working) ? (
                    <div className="offhours" style={{ top: 0, height }} />
                  ) : (
                    <>
                      {h.startMin > DAY_START &&
                        <div className="offhours" style={{ top: 0, height: (h.startMin - DAY_START) * PX_MIN }} />}
                      {h.endMin < DAY_END &&
                        <div className="offhours" style={{ top: (h.endMin - DAY_START) * PX_MIN, height: (DAY_END - h.endMin) * PX_MIN }} />}
                    </>
                  )}
                  {c.appts.filter((a) => a.status !== 'cancelled').map((a) => (
                    <div key={a.id} className={`appt ${a.status}`}
                      style={{
                        top: (a.startMin - DAY_START) * PX_MIN,
                        height: Math.max((a.endMin - a.startMin) * PX_MIN - 2, 18),
                        borderLeftColor: a.staff.color,
                      }}
                      onClick={(e) => { e.stopPropagation(); setDetail(a); }}>
                      <div className="t">{fmtTime(a.startMin)} · {a.status === 'no_show' ? 'No-show' : a.status}
                        {a.source === 'online' ? ' · online' : ''}</div>
                      <div className="c">{clientName(a)}</div>
                      <div>{a.service.name}</div>
                    </div>
                  ))}
                </div>
              );
            })}
          </div>
        </div>
      </div>
      {createAt && <NewApptModal preset={createAt} onClose={() => setCreateAt(null)} onDone={() => { setCreateAt(null); load(); }} />}
      {detail && <ApptDetailModal appt={detail} onClose={() => setDetail(null)} onDone={() => { setDetail(null); load(); }}
        onCheckout={() => openCheckout(detail)} />}
      {checkout && <CheckoutModal appts={checkout} onClose={() => setCheckout(null)} onDone={() => { setCheckout(null); load(); }} />}
    </>
  );
}

/* ---------- new appointment ---------- */
function NewApptModal({ preset, onClose, onDone }:
  { preset: { staffId: string; date: string; startMin: number }; onClose: () => void; onDone: () => void }) {
  const { staff, services } = useAppData();
  const toast = useToast();
  const active = staff.filter((s) => s.active);
  const [staffId, setStaffId] = useState(preset.staffId);
  const [date, setDate] = useState(preset.date);
  const [startMin, setStartMin] = useState(preset.startMin);
  const [notes, setNotes] = useState('');
  const [err, setErr] = useState('');
  const [q, setQ] = useState('');
  const [found, setFound] = useState<Client[]>([]);
  const [picked, setPicked] = useState<Client | null>(null);
  const [newClient, setNewClient] = useState(false);
  const [nc, setNc] = useState({ firstName: '', lastName: '', phone: '', email: '' });

  const st = active.find((s) => s.id === staffId);
  const options = services.filter((sv) => sv.active && (st?.serviceIds.includes(sv.id) ?? true));
  const list = options.length ? options : services.filter((s) => s.active);
  const [serviceId, setServiceId] = useState(list[0]?.id ?? '');
  useEffect(() => { if (!list.find((s) => s.id === serviceId)) setServiceId(list[0]?.id ?? ''); }, [staffId]);

  useEffect(() => {
    if (!q.trim()) { setFound([]); return; }
    const t = setTimeout(async () => {
      const d = await gql<{ clients: Client[] }>(
        'query($q: String) { clients(q: $q) { id firstName lastName phone } }', { q });
      setFound(d.clients.slice(0, 6));
    }, 200);
    return () => clearTimeout(t);
  }, [q]);

  const save = async () => {
    try {
      const vars: Record<string, unknown> = { staffId, serviceId, date, startMin: Number(startMin), notes };
      if (picked) vars.clientId = picked.id;
      else if (newClient && nc.firstName.trim()) vars.client = nc;
      else throw new Error('Pick a client or add a new one.');
      await gql(
        `mutation($clientId: ID, $client: ClientInput, $staffId: ID!, $serviceId: ID!, $date: Date!, $startMin: Int!, $notes: String) {
          createAppointment(clientId: $clientId, client: $client, staffId: $staffId, serviceId: $serviceId,
            date: $date, startMin: $startMin, notes: $notes) { id } }`, vars);
      toast('Appointment booked');
      onDone();
    } catch (e) { setErr((e as Error).message); }
  };

  return (
    <Modal onClose={onClose} wide>
      <h2>New appointment</h2>
      <label>Client</label>
      <input placeholder="Search clients by name, phone, email…" value={q} onChange={(e) => setQ(e.target.value)} />
      <div>
        {found.map((c) => (
          <button key={c.id} className="btn btn-sm" style={{ margin: '4px 4px 0 0' }}
            onClick={() => { setPicked(c); setNewClient(false); setQ(''); setFound([]); }}>
            {c.firstName} {c.lastName} <span className="fainttext">{c.phone}</span>
          </button>
        ))}
      </div>
      {picked && <div className="fainttext" style={{ marginTop: 4 }}>✓ {picked.firstName} {picked.lastName}</div>}
      <button className="btn btn-sm" style={{ marginTop: 6 }} onClick={() => { setNewClient(true); setPicked(null); }}>
        <Icon name="plus" size={14} /> New client
      </button>
      {newClient && (
        <div className="grid2">
          <div><label>First name</label><input value={nc.firstName} onChange={(e) => setNc({ ...nc, firstName: e.target.value })} /></div>
          <div><label>Last name</label><input value={nc.lastName} onChange={(e) => setNc({ ...nc, lastName: e.target.value })} /></div>
          <div><label>Phone</label><input value={nc.phone} onChange={(e) => setNc({ ...nc, phone: e.target.value })} /></div>
          <div><label>Email</label><input value={nc.email} onChange={(e) => setNc({ ...nc, email: e.target.value })} /></div>
        </div>
      )}
      <div className="grid2">
        <div><label>Team member</label>
          <select value={staffId} onChange={(e) => setStaffId(e.target.value)}>
            {active.map((s) => <option key={s.id} value={s.id}>{s.name}</option>)}
          </select>
        </div>
        <div><label>Service</label>
          <select value={serviceId} onChange={(e) => setServiceId(e.target.value)}>
            {list.map((sv) => (
              <option key={sv.id} value={sv.id}>{sv.name} · {fmtDur(sv.durationMin)} · {fmtMAD(sv.priceCents)}</option>
            ))}
          </select>
        </div>
        <div><label>Date</label><input type="date" value={date} onChange={(e) => setDate(e.target.value)} /></div>
        <div><label>Time</label>
          <select value={startMin} onChange={(e) => setStartMin(Number(e.target.value))}>
            {timeOptions().map((m) => <option key={m} value={m}>{fmtTime(m)}</option>)}
          </select>
        </div>
      </div>
      <label>Notes</label>
      <textarea rows={2} value={notes} onChange={(e) => setNotes(e.target.value)} />
      <div className="err">{err}</div>
      <div className="actions">
        <button className="btn" onClick={onClose}>Cancel</button>
        <button className="btn btn-primary" onClick={save}>Save appointment</button>
      </div>
    </Modal>
  );
}

/* ---------- appointment detail ---------- */
function ApptDetailModal({ appt: a, onClose, onDone, onCheckout }:
  { appt: Appointment; onClose: () => void; onDone: () => void; onCheckout: () => void }) {
  const { staff } = useAppData();
  const toast = useToast();
  const active = staff.filter((s) => s.active);
  const [date, setDate] = useState(a.date);
  const [startMin, setStartMin] = useState(a.startMin);
  const [staffId, setStaffId] = useState(a.staff.id);
  // Edited in MAD, sent as centimes.
  const [priceMad, setPriceMad] = useState(centsToMad(a.priceCents));
  const [notes, setNotes] = useState(a.notes);
  const [err, setErr] = useState('');

  const open = !['completed', 'cancelled', 'no_show'].includes(a.status);

  const patch = async (vars: Record<string, unknown>, msg: string) => {
    try {
      await gql(
        `mutation($id: ID!, $status: String, $date: Date, $startMin: Int, $staffId: ID, $priceCents: Int, $notes: String) {
          updateAppointment(id: $id, status: $status, date: $date, startMin: $startMin,
            staffId: $staffId, priceCents: $priceCents, notes: $notes) { id } }`,
        { id: a.id, ...vars });
      toast(msg);
      onDone();
    } catch (e) { setErr((e as Error).message); }
  };

  return (
    <Modal onClose={onClose} wide>
      <h2>{clientName(a)}{' '}
        {a.client.allergies && <span className="badge allergy" title={a.client.allergies}>
          <Icon name="alert" size={12} /> allergy</span>}
      </h2>
      <div className="mutetext">{a.service.name} with {a.staff.name}</div>
      <div style={{ margin: '10px 0 4px' }}>
        <StatusBadge status={a.status} />{' '}
        {a.source === 'online' && <span className="badge online">online · {a.bookingRef}</span>}{' '}
        <b style={{ marginLeft: 6 }}>{fmtMAD(a.priceCents)}</b>
      </div>
      <div className="mutetext">{fmtDateLong(a.date)} · {fmtTime(a.startMin)} – {fmtTime(a.endMin)}</div>
      <div className="grid2">
        <div><label>Date</label><input type="date" value={date} onChange={(e) => setDate(e.target.value)} /></div>
        <div><label>Time</label>
          <select value={startMin} onChange={(e) => setStartMin(Number(e.target.value))}>
            {timeOptions().map((m) => <option key={m} value={m}>{fmtTime(m)}</option>)}
          </select>
        </div>
        <div><label>Team member</label>
          <select value={staffId} onChange={(e) => setStaffId(e.target.value)}>
            {active.map((s) => <option key={s.id} value={s.id}>{s.name}</option>)}
          </select>
        </div>
        <div><label>Price</label>
          <input type="number" step="0.01" min="0" value={priceMad}
            onChange={(e) => setPriceMad(Number(e.target.value))} />
        </div>
      </div>
      <label>Notes</label>
      <textarea rows={2} value={notes} onChange={(e) => setNotes(e.target.value)} />
      <div className="err">{err}</div>
      <div className="actions" style={{ justifyContent: 'space-between' }}>
        <span>
          {open && <>
            <button className="btn btn-sm btn-danger" onClick={() => patch({ status: 'cancelled' }, 'Cancelled')}>Cancel visit</button>{' '}
            <button className="btn btn-sm btn-danger" onClick={() => patch({ status: 'no_show' }, 'Marked as no-show')}>No-show</button>
          </>}
        </span>
        <span style={{ display: 'flex', gap: 8 }}>
          <button className="btn" onClick={onClose}>Close</button>
          <button className="btn" onClick={() => patch(
            { date, startMin, staffId, priceCents: madToCents(priceMad), notes },
            'Appointment updated')}>Save changes</button>
          {a.status === 'booked' &&
            <button className="btn" onClick={() => patch({ status: 'confirmed' }, 'Confirmed')}>Confirm</button>}
          {open && <button className="btn btn-primary" onClick={onCheckout}>Check out</button>}
        </span>
      </div>
    </Modal>
  );
}

/* ---------- checkout (POS) ---------- */
function CheckoutModal({ appts, onClose, onDone }:
  { appts: Appointment[]; onClose: () => void; onDone: () => void }) {
  const toast = useToast();
  // All amounts here are centimes; only the custom-tip input is in MAD.
  const subtotalCents = appts.reduce((s, x) => s + x.priceCents, 0);
  const [tipCents, setTipCents] = useState(0);
  const [tipChip, setTipChip] = useState(0);
  const [custom, setCustom] = useState('');
  const [method, setMethod] = useState('card');
  const [err, setErr] = useState('');

  const pay = async () => {
    try {
      await gql(
        `mutation($ids: [ID!]!, $tipCents: Int, $method: String) {
          checkout(appointmentIds: $ids, tipCents: $tipCents, paymentMethod: $method) {
            id totalCents } }`,
        { ids: appts.map((x) => x.id), tipCents, method });
      toast(`Sale completed — ${fmtMAD(subtotalCents + tipCents)}`);
      onDone();
    } catch (e) { setErr((e as Error).message); }
  };

  return (
    <Modal onClose={onClose}>
      <h2>Checkout</h2>
      <div className="mutetext">{clientName(appts[0])} · {fmtDateShort(appts[0].date)}</div>
      <div className="hist" style={{ marginTop: 12 }}>
        {appts.map((x) => (
          <div key={x.id} className="hist-row">
            <div className="grow"><b>{x.service.name}</b>
              <div className="fainttext">{fmtTime(x.startMin)} · {x.staff.name}</div>
            </div>
            <div className="num">{fmtMAD(x.priceCents)}</div>
          </div>
        ))}
      </div>
      <label>Tip</label>
      <div className="chip-row">
        {[0, 10, 15, 20].map((p) => (
          <button key={p} className={`chip ${tipChip === p && custom === '' ? 'active' : ''}`}
            onClick={() => {
              setTipChip(p);
              setCustom('');
              setTipCents(Math.round((subtotalCents * p) / 100));
            }}>
            {p === 0 ? 'No tip' : `${p}%`}
          </button>
        ))}
        <input type="number" placeholder="Custom MAD" min="0" step="0.01" style={{ width: 120 }}
          value={custom}
          onChange={(e) => {
            setCustom(e.target.value);
            setTipCents(Math.max(0, madToCents(e.target.value)));
          }} />
      </div>
      <label>Payment method</label>
      <div className="chip-row">
        <button className={`chip ${method === 'card' ? 'active' : ''}`} onClick={() => setMethod('card')}>
          <Icon name="card" size={15} /> Card</button>
        <button className={`chip ${method === 'cash' ? 'active' : ''}`} onClick={() => setMethod('cash')}>
          <Icon name="banknote" size={15} /> Cash</button>
      </div>
      <div className="summary-card" style={{ position: 'static', padding: '14px 0 0' }}>
        <div className="line"><span>Subtotal</span><b>{fmtMAD(subtotalCents)}</b></div>
        <div className="line"><span>Tip</span><b>{fmtMAD(tipCents)}</b></div>
        <div className="line total">
          <span>Total</span><span>{fmtMAD(subtotalCents + tipCents)}</span>
        </div>
      </div>
      <div className="err">{err}</div>
      <div className="actions">
        <button className="btn" onClick={onClose}>Back</button>
        <button className="btn btn-accent" onClick={pay}>Complete sale</button>
      </div>
    </Modal>
  );
}

/** A closure as the calendar draws it: a minute band on one day. */
interface Closure {
  id: string;
  date: string;
  endDate: string | null;
  startMin: number | null;
  endMin: number | null;
  reason: string;
}

/**
 * The shaded bands for one date.
 *
 * A whole-day closure has null times and covers everything; a part-day one
 * covers its window. Spans are expanded per day here rather than server-side so
 * the calendar can draw each column independently.
 */
/**
 * Closure bands overlapping this date, clipped to the visible hours.
 *
 * Clipped here rather than at render: a closure wholly outside the grid — the
 * 00:00–07:00 half of a whole-day one, say — otherwise produced a band with a
 * negative height, which is invalid CSS that happens to look like nothing.
 */
function closedBands(closures: Closure[], date: string) {
  return closures
    .filter((c) => date >= c.date && date <= (c.endDate || c.date))
    .map((c) => ({
      from: Math.max(c.startMin ?? 0, DAY_START),
      to: Math.min(c.endMin ?? 24 * 60, DAY_END),
      reason: c.reason,
    }))
    .filter((band) => band.to > band.from);
}
