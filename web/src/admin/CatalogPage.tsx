// Catalog: categories and services with staff assignment.
import { useState } from 'react';
import { gql } from '../lib/gql';
import type { Service } from '../lib/types';
import { useAppData } from './AdminLayout';
import { Modal, useToast } from '../components/ui';
import { Icon } from '../lib/icons';
import { centsToMad, fmtDur, fmtMAD, madToCents } from '../lib/format';

export default function CatalogPage() {
  const { categories, services, staff, refresh } = useAppData();
  const [editing, setEditing] = useState<Service | 'new' | null>(null);
  const [newCat, setNewCat] = useState(false);

  return (
    <>
      <div className="page-head">
        <h1>Service catalog</h1><div className="grow" />
        <button className="btn" onClick={() => setNewCat(true)}><Icon name="plus" size={16} /> Category</button>
        <button className="btn btn-primary" onClick={() => setEditing('new')}>
          <Icon name="plus" size={16} /> New service
        </button>
      </div>
      {categories.map((cat) => {
        const svcs = services.filter((s) => s.categoryId === cat.id);
        return (
          <div key={cat.id} className="card" style={{ marginBottom: 16 }}>
            <div className="pad" style={{ paddingBottom: 0 }}><h2 style={{ fontSize: 16 }}>{cat.name}</h2></div>
            <table className="list">
              <thead><tr>
                <th>Service</th><th>Duration</th><th className="num">Price</th><th>Performed by</th><th></th>
              </tr></thead>
              <tbody>
                {svcs.map((s) => (
                  <tr key={s.id} className={s.active ? '' : 'mutetext'}>
                    <td><b>{s.name}</b>{!s.active && <> <span className="badge cancelled">hidden</span></>}
                      <div className="fainttext">{s.description}</div>
                    </td>
                    <td>{fmtDur(s.durationMin)}</td>
                    <td className="num">{fmtMAD(s.priceCents)}</td>
                    <td>
                      <span className="chip-row">
                        {staff.filter((st) => st.serviceIds.includes(s.id)).map((st) => (
                          <span key={st.id} className="dot" title={st.name} style={{ background: st.color }} />
                        ))}
                      </span>
                    </td>
                    <td className="num"><button className="btn btn-sm" onClick={() => setEditing(s)}>Edit</button></td>
                  </tr>
                ))}
                {svcs.length === 0 && <tr><td colSpan={5} className="empty">No services yet</td></tr>}
              </tbody>
            </table>
          </div>
        );
      })}
      {editing && <ServiceModal service={editing === 'new' ? null : editing}
        onClose={() => setEditing(null)} onDone={() => { setEditing(null); refresh(); }} />}
      {newCat && <NewCategoryModal onClose={() => setNewCat(false)}
        onDone={() => { setNewCat(false); refresh(); }} />}
    </>
  );
}

function ServiceModal({ service, onClose, onDone }:
  { service: Service | null; onClose: () => void; onDone: () => void }) {
  const { categories, staff } = useAppData();
  const toast = useToast();
  const [f, setF] = useState({
    name: service?.name ?? '',
    description: service?.description ?? '',
    categoryId: service?.categoryId ?? categories[0]?.id ?? '',
    durationMin: service?.durationMin ?? 60,
    // Held as MAD because that is what the owner types; converted to centimes
    // at the API boundary.
    priceMad: service ? centsToMad(service.priceCents) : 200,
    active: service?.active ?? true,
  });
  const [staffIds, setStaffIds] = useState<string[]>(
    service ? staff.filter((st) => st.serviceIds.includes(service.id)).map((st) => st.id) : []);
  const [err, setErr] = useState('');

  const save = async () => {
    try {
      if (!f.name.trim()) throw new Error('Name is required');
      const { priceMad, ...rest } = f;
      const vars = { ...rest, priceCents: madToCents(priceMad), staffIds };

      if (service) {
        await gql(
          `mutation($id: ID!, $categoryId: ID, $name: String, $description: String,
            $durationMin: Int, $priceCents: Int, $active: Boolean, $staffIds: [ID!]) {
            updateService(id: $id, categoryId: $categoryId, name: $name, description: $description,
              durationMin: $durationMin, priceCents: $priceCents, active: $active,
              staffIds: $staffIds) { id } }`,
          { id: service.id, ...vars });
      } else {
        await gql(
          `mutation($categoryId: ID!, $name: String!, $description: String,
            $durationMin: Int!, $priceCents: Int!, $staffIds: [ID!]) {
            createService(categoryId: $categoryId, name: $name, description: $description,
              durationMin: $durationMin, priceCents: $priceCents, staffIds: $staffIds) { id } }`,
          vars);
      }
      toast('Service saved');
      onDone();
    } catch (e) { setErr((e as Error).message); }
  };

  return (
    <Modal onClose={onClose}>
      <h2>{service ? 'Edit service' : 'New service'}</h2>
      <label>Name</label><input value={f.name} onChange={(e) => setF({ ...f, name: e.target.value })} />
      <label>Description</label>
      <input value={f.description} onChange={(e) => setF({ ...f, description: e.target.value })} />
      <div className="grid2">
        <div><label>Category</label>
          <select value={f.categoryId} onChange={(e) => setF({ ...f, categoryId: e.target.value })}>
            {categories.map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}
          </select>
        </div>
        <div><label>Duration</label>
          <select value={f.durationMin} onChange={(e) => setF({ ...f, durationMin: Number(e.target.value) })}>
            {[15, 30, 45, 60, 75, 90, 120, 150, 180].map((m) => <option key={m} value={m}>{fmtDur(m)}</option>)}
          </select>
        </div>
      </div>
      <label>Price (MAD)</label>
      <input type="number" step="0.01" min="0" value={f.priceMad}
        onChange={(e) => setF({ ...f, priceMad: Number(e.target.value) })} />
      <label>Performed by</label>
      <div className="checkgrid">
        {staff.filter((s) => s.active).map((st) => (
          <label key={st.id}>
            <input type="checkbox" checked={staffIds.includes(st.id)}
              onChange={(e) => setStaffIds(e.target.checked
                ? [...staffIds, st.id] : staffIds.filter((x) => x !== st.id))} />
            <span className="dot" style={{ background: st.color }} />{st.name}
          </label>
        ))}
      </div>
      {service && (
        <label style={{ marginTop: 14, display: 'flex', gap: 7, alignItems: 'center' }}>
          <input type="checkbox" style={{ width: 'auto' }} checked={f.active}
            onChange={(e) => setF({ ...f, active: e.target.checked })} /> Bookable online
        </label>
      )}
      <div className="err">{err}</div>
      <div className="actions">
        <button className="btn" onClick={onClose}>Cancel</button>
        <button className="btn btn-primary" onClick={save}>Save service</button>
      </div>
    </Modal>
  );
}

function NewCategoryModal({ onClose, onDone }: { onClose: () => void; onDone: () => void }) {
  const [name, setName] = useState('');
  return (
    <Modal onClose={onClose}>
      <h2>New category</h2>
      <label>Name</label><input value={name} onChange={(e) => setName(e.target.value)} />
      <div className="actions">
        <button className="btn" onClick={onClose}>Cancel</button>
        <button className="btn btn-primary" onClick={async () => {
          if (!name.trim()) return;
          await gql('mutation($name: String!) { createCategory(name: $name) { id } }', { name });
          onDone();
        }}>Add</button>
      </div>
    </Modal>
  );
}
