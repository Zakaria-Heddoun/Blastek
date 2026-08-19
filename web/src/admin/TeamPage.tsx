// Team: staff cards with working-hours editor and service assignment.
import { useState } from 'react';
import { useTranslation } from 'react-i18next';
import { gql } from '../lib/gql';
import type { Staff, StaffHour } from '../lib/types';
import { useAppData } from './AdminLayout';
import MembersTab from './MembersTab';
import TimeOffTab from './TimeOffTab';
import { Modal, useToast } from '../components/ui';
import { Icon } from '../lib/icons';
import { fmtTime, initials, weekdaysShort } from '../lib/format';

const defaultHours = (): StaffHour[] =>
  [...Array(7)].map((_, wd) => ({ weekday: wd, working: wd !== 0, startMin: 540, endMin: 1080 }));

function timeRange(from: number, to: number) {
  const out: number[] = [];
  for (let m = from; m <= to; m += 15) out.push(m);
  return out;
}

export default function TeamPage() {
  const { t } = useTranslation();
  const { staff, refresh } = useAppData();
  const [editing, setEditing] = useState<Staff | 'new' | null>(null);
  const [tab, setTab] = useState<'roster' | 'access' | 'timeoff'>('roster');

  return (
    <>
      <div className="page-head">
        <h1>{t(`admin.team.title`)}</h1>
        {/* Two different things share this page: who takes appointments, and
            who can sign in. Tabs rather than one list, because conflating them
            is how "remove their access" deletes a year of history. */}
        <div className="team-tabs" role="tablist">
          <button
            role="tab"
            aria-selected={tab === 'roster'}
            className={tab === 'roster' ? 'active' : ''}
            onClick={() => setTab('roster')}
          >
            {t(`admin.team.roster`)}
          </button>
          <button
            role="tab"
            aria-selected={tab === 'access'}
            className={tab === 'access' ? 'active' : ''}
            onClick={() => setTab('access')}
          >
            {t(`admin.team.access`)}
          </button>
          {/* The calendar shows a block on the day it falls. This answers the
              question the calendar cannot: whether anyone is away next month,
              which is what an owner checks before promising a date. */}
          <button
            role="tab"
            aria-selected={tab === 'timeoff'}
            className={tab === 'timeoff' ? 'active' : ''}
            onClick={() => setTab('timeoff')}
          >
            {t(`admin.team.timeOff`)}
          </button>
        </div>
        <div className="grow" />
        {tab === 'roster' && (
          <button className="btn btn-primary" onClick={() => setEditing('new')}>
            <Icon name="plus" size={16} /> {t(`admin.team.addMember`)}
          </button>
        )}
      </div>

      {tab === 'access' && <MembersTab staff={staff} />}
      {tab === 'timeoff' && <TimeOffTab />}

      {tab === 'roster' && (
        <div className="cards">
        {staff.map((st) => (
          <div key={st.id} className={`card staff-card ${st.active ? '' : 'mutetext'}`}>
            <div className="top">
              <div className="avatar" style={{ background: st.color }}>{initials(st.name)}</div>
              <div><b>{st.name}</b>{!st.active && <> <span className="badge cancelled">inactive</span></>}
                <div className="fainttext">{st.role}</div>
              </div>
            </div>
            <div className="fainttext">
              {st.hours.filter((h) => h.working).length} working days · {st.serviceIds.length} services
            </div>
            <div className="fainttext">
              {st.hours.filter((h) => h.working).map((h) => weekdaysShort()[h.weekday]).join(', ') || t('admin.team.noWorkingDays')}
            </div>
            <button className="btn btn-sm" style={{ alignSelf: 'flex-start' }} onClick={() => setEditing(st)}>{t(`common.edit`)}</button>
          </div>
        ))}
        </div>
      )}

      {editing && <StaffModal staff={editing === 'new' ? null : editing}
        onClose={() => setEditing(null)} onDone={() => { setEditing(null); refresh(); }} />}
    </>
  );
}

function StaffModal({ staff: st, onClose, onDone }:
  { staff: Staff | null; onClose: () => void; onDone: () => void }) {
  const { t } = useTranslation();
  const { services } = useAppData();
  const toast = useToast();
  const [f, setF] = useState({
    name: st?.name ?? '', role: st?.role ?? '', color: st?.color ?? '#D8B88A',
    active: st?.active ?? true,
  });
  const [hours, setHours] = useState<StaffHour[]>(
    st ? [...st.hours].sort((a, b) => a.weekday - b.weekday) : defaultHours());
  const [serviceIds, setServiceIds] = useState<string[]>(st?.serviceIds ?? []);
  const [err, setErr] = useState('');

  const setHour = (wd: number, patch: Partial<StaffHour>) =>
    setHours(hours.map((h) => (h.weekday === wd ? { ...h, ...patch } : h)));

  const save = async () => {
    try {
      if (!f.name.trim()) throw new Error(t('admin.team.nameRequired'));
      const vars = { ...f, hours, serviceIds };
      if (st) {
        await gql(
          `mutation($id: ID!, $name: String, $role: String, $color: String, $active: Boolean,
            $hours: [StaffHourInput!], $serviceIds: [ID!]) {
            updateStaff(id: $id, name: $name, role: $role, color: $color, active: $active,
              hours: $hours, serviceIds: $serviceIds) { id } }`,
          { id: st.id, ...vars });
      } else {
        await gql(
          `mutation($name: String!, $role: String, $color: String, $active: Boolean,
            $hours: [StaffHourInput!], $serviceIds: [ID!]) {
            createStaff(name: $name, role: $role, color: $color, active: $active,
              hours: $hours, serviceIds: $serviceIds) { id } }`,
          vars);
      }
      toast(t('admin.team.saved'));
      onDone();
    } catch (e) { setErr((e as Error).message); }
  };

  return (
    <Modal onClose={onClose} wide>
      <h2>{st ? `Edit ${st.name}` : t('admin.team.addMemberTitle')}</h2>
      <div className="grid2">
        <div><label>{t(`common.name`)}</label><input value={f.name} onChange={(e) => setF({ ...f, name: e.target.value })} /></div>
        <div><label>{t(`admin.team.role`)}</label><input value={f.role} onChange={(e) => setF({ ...f, role: e.target.value })} /></div>
        <div><label>{t(`admin.team.calendarColor`)}</label>
          <input type="color" style={{ height: 38, width: '100%' }} value={f.color}
            onChange={(e) => setF({ ...f, color: e.target.value })} /></div>
        <div><label>{t(`common.status`)}</label>
          <select value={f.active ? '1' : '0'} onChange={(e) => setF({ ...f, active: e.target.value === '1' })}>
            <option value="1">{t(`admin.team.active`)}</option><option value="0">{t(`admin.team.inactive`)}</option>
          </select>
        </div>
      </div>
      <label>{t(`admin.team.workingHours`)}</label>
      <div className="hours-editor">
        {hours.map((h) => (
          <FragmentRow key={h.weekday} h={h} setHour={setHour} />
        ))}
      </div>
      <label>{t(`admin.team.servicesPerformed`)}</label>
      <div className="checkgrid">
        {services.filter((s) => s.active).map((sv) => (
          <label key={sv.id}>
            <input type="checkbox" className="toggle-switch" checked={serviceIds.includes(sv.id)}
              onChange={(e) => setServiceIds(e.target.checked
                ? [...serviceIds, sv.id] : serviceIds.filter((x) => x !== sv.id))} />
            {sv.name}
          </label>
        ))}
      </div>
      <div className="err">{err}</div>
      <div className="actions">
        <button className="btn" onClick={onClose}>{t(`common.cancel`)}</button>
        <button className="btn btn-primary" onClick={save}>{t(`common.save`)}</button>
      </div>
    </Modal>
  );
}

function FragmentRow({ h, setHour }:
  { h: StaffHour; setHour: (wd: number, patch: Partial<StaffHour>) => void }) {
  const { t } = useTranslation();
  return (
    <>
      <span className="wd">{weekdaysShort()[h.weekday]}</span>
      <label>
        <input type="checkbox" className="toggle-switch" checked={h.working}
          onChange={(e) => setHour(h.weekday, { working: e.target.checked })} /> works
      </label>
      <select value={h.startMin} onChange={(e) => setHour(h.weekday, { startMin: Number(e.target.value) })}>
        {timeRange(420, 900).map((m) => <option key={m} value={m}>{fmtTime(m)}</option>)}
      </select>
      <select value={h.endMin} onChange={(e) => setHour(h.weekday, { endMin: Number(e.target.value) })}>
        {timeRange(600, 1320).map((m) => <option key={m} value={m}>{fmtTime(m)}</option>)}
      </select>
    </>
  );
}
