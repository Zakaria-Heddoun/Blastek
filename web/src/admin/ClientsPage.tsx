// Clients: searchable directory + profile with allergy alert, notes and history.
import { useEffect, useState } from 'react';
import { gql } from '../lib/gql';
import type { Client } from '../lib/types';
import { Modal, StatusBadge, useToast } from '../components/ui';
import { Icon } from '../lib/icons';
import { fmtDateShort, fmtMAD, fmtTime, initials } from '../lib/format';
import Pager, { PAGE_SIZE } from '../components/Pager';

const LIST = `query($q: String, $limit: Int, $offset: Int) {
  clients(q: $q, limit: $limit, offset: $offset) {
    totalCount
    items { id firstName lastName email phone allergies apptCount totalSpentCents }
  }
}`;

const DETAIL = `query($id: ID!) {
  client(id: $id) {
    id firstName lastName email phone allergies notes createdAt apptCount totalSpentCents
    appointments { id date startMin status priceCents service { name } staff { name } }
  }
}`;

export default function ClientsPage() {
  const toast = useToast();
  const [q, setQ] = useState('');
  const [rows, setRows] = useState<Client[]>([]);
  const [total, setTotal] = useState(0);
  const [offset, setOffset] = useState(0);
  const [selected, setSelected] = useState<string | null>(null);
  const [detail, setDetail] = useState<Client | null>(null);
  const [showNew, setShowNew] = useState(false);

  const load = async (query = q, from = offset) => {
    const d = await gql<{ clients: { items: Client[]; totalCount: number } }>(
      LIST, { q: query, limit: PAGE_SIZE, offset: from });
    setRows(d.clients.items);
    setTotal(d.clients.totalCount);
  };

  const show = async (id: string) => {
    setSelected(id);
    const d = await gql<{ client: Client }>(DETAIL, { id });
    setDetail(d.client);
  };

  // A new search starts from the first page — otherwise a narrow result set
  // lands on an offset past its end and looks empty.
  useEffect(() => {
    const t = setTimeout(() => { setOffset(0); load(q, 0); }, 200);
    return () => clearTimeout(t);
  }, [q]);

  const goTo = (next: number) => { setOffset(next); load(q, next); };

  const saveProfile = async () => {
    if (!detail) return;
    await gql(
      `mutation($id: ID!, $input: ClientInput!) { updateClient(id: $id, input: $input) { id } }`,
      { id: detail.id, input: {
        firstName: detail.firstName, lastName: detail.lastName, email: detail.email,
        phone: detail.phone, allergies: detail.allergies, notes: detail.notes,
      }});
    toast('Profile saved');
    load();
  };

  const set = (patch: Partial<Client>) => setDetail((d) => (d ? { ...d, ...patch } : d));

  return (
    <>
      <div className="page-head">
        <h1>Clients</h1><div className="grow" />
        <button className="btn btn-primary" onClick={() => setShowNew(true)}>
          <Icon name="plus" size={16} /> New client
        </button>
      </div>
      <div className="split">
        <div className="card">
          <div className="pad" style={{ paddingBottom: 10 }}>
            <input placeholder="Search name, email or phone…" style={{ width: '100%' }}
              value={q} onChange={(e) => setQ(e.target.value)} />
          </div>
          <table className="list">
            <thead><tr><th>Client</th><th className="num">Visits</th><th className="num">Total spent</th></tr></thead>
            <tbody>
              {rows.map((c) => (
                <tr key={c.id} className={`rowlink ${c.id === selected ? 'sel' : ''}`} onClick={() => show(c.id)}>
                  <td>
                    <b>{c.firstName} {c.lastName}</b>{' '}
                    {c.allergies && <span className="badge allergy"><Icon name="alert" size={12} /></span>}
                    <div className="fainttext">{c.phone}{c.phone && c.email ? ' · ' : ''}{c.email}</div>
                  </td>
                  <td className="num">{c.apptCount}</td>
                  <td className="num">{fmtMAD(c.totalSpentCents ?? 0)}</td>
                </tr>
              ))}
              {rows.length === 0 && <tr><td colSpan={3} className="empty">No clients found</td></tr>}
            </tbody>
          </table>
          <Pager offset={offset} limit={PAGE_SIZE} totalCount={total} onChange={goTo} />
        </div>
        <div className="card pad">
          {!detail ? (
            <div className="empty">Select a client to view their profile</div>
          ) : (
            <>
              <div className="detail-head">
                <div className="avatar">{initials(`${detail.firstName} ${detail.lastName}`)}</div>
                <div>
                  <h2>{detail.firstName} {detail.lastName}</h2>
                  <div className="fainttext">
                    Client since {detail.createdAt?.slice(0, 10)} · {detail.appointments?.length} appointments ·{' '}
                    {fmtMAD(detail.totalSpentCents ?? 0)} spent
                  </div>
                </div>
              </div>
              {detail.allergies && (
                <div style={{ marginTop: 10 }}>
                  <span className="badge allergy"><Icon name="alert" size={12} /> {detail.allergies}</span>
                </div>
              )}
              <div className="grid2">
                <div><label>First name</label>
                  <input value={detail.firstName} onChange={(e) => set({ firstName: e.target.value })} /></div>
                <div><label>Last name</label>
                  <input value={detail.lastName} onChange={(e) => set({ lastName: e.target.value })} /></div>
                <div><label>Email</label>
                  <input value={detail.email} onChange={(e) => set({ email: e.target.value })} /></div>
                <div><label>Phone</label>
                  <input value={detail.phone} onChange={(e) => set({ phone: e.target.value })} /></div>
              </div>
              <label>Allergies & alerts</label>
              <input value={detail.allergies} onChange={(e) => set({ allergies: e.target.value })} />
              <label>Notes</label>
              <textarea rows={2} value={detail.notes} onChange={(e) => set({ notes: e.target.value })} />
              <div style={{ display: 'flex', justifyContent: 'flex-end', marginTop: 12 }}>
                <button className="btn btn-primary" onClick={saveProfile}>Save profile</button>
              </div>
              <h3 style={{ marginTop: 18 }}>History & upcoming</h3>
              <div className="hist">
                {detail.appointments?.map((a) => (
                  <div key={a.id} className="hist-row">
                    <div className="fainttext" style={{ width: 100 }}>
                      {fmtDateShort(a.date)}<br />{fmtTime(a.startMin)}
                    </div>
                    <div className="grow"><b>{a.service.name}</b>
                      <div className="fainttext">with {a.staff.name}</div>
                    </div>
                    <StatusBadge status={a.status} />
                    <div className="num" style={{ width: 80 }}>{fmtMAD(a.priceCents)}</div>
                  </div>
                ))}
                {!detail.appointments?.length && <div className="empty">No appointments yet</div>}
              </div>
            </>
          )}
        </div>
      </div>
      {showNew && <NewClientModal onClose={() => setShowNew(false)}
        onDone={(id) => { setShowNew(false); load(); show(id); }} />}
    </>
  );
}

function NewClientModal({ onClose, onDone }: { onClose: () => void; onDone: (id: string) => void }) {
  const toast = useToast();
  const [f, setF] = useState({ firstName: '', lastName: '', email: '', phone: '', allergies: '' });
  const [err, setErr] = useState('');

  const save = async () => {
    try {
      if (!f.firstName.trim()) throw new Error('First name is required');
      const d = await gql<{ createClient: { id: string } }>(
        'mutation($input: ClientInput!) { createClient(input: $input) { id } }', { input: f });
      toast('Client added');
      onDone(d.createClient.id);
    } catch (e) { setErr((e as Error).message); }
  };

  return (
    <Modal onClose={onClose}>
      <h2>New client</h2>
      <div className="grid2">
        <div><label>First name</label><input value={f.firstName} onChange={(e) => setF({ ...f, firstName: e.target.value })} /></div>
        <div><label>Last name</label><input value={f.lastName} onChange={(e) => setF({ ...f, lastName: e.target.value })} /></div>
        <div><label>Email</label><input value={f.email} onChange={(e) => setF({ ...f, email: e.target.value })} /></div>
        <div><label>Phone</label><input value={f.phone} onChange={(e) => setF({ ...f, phone: e.target.value })} /></div>
      </div>
      <label>Allergies & alerts</label>
      <input value={f.allergies} onChange={(e) => setF({ ...f, allergies: e.target.value })} />
      <div className="err">{err}</div>
      <div className="actions">
        <button className="btn" onClick={onClose}>Cancel</button>
        <button className="btn btn-primary" onClick={save}>Add client</button>
      </div>
    </Modal>
  );
}
