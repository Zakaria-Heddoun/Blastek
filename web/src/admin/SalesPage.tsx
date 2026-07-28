// Sales: transaction ledger with quick date ranges.
import { useEffect, useState } from 'react';
import { gql } from '../lib/gql';
import type { Sale } from '../lib/types';
import { Icon } from '../lib/icons';
import { addDays, fmtDateShort, fmtMoney, todayStr } from '../lib/format';

const QUERY = `query($from: Date!) {
  sales(from: $from) {
    id tip total paymentMethod createdAt
    client { firstName lastName }
    items { id description }
  }
}`;

export default function SalesPage() {
  const [days, setDays] = useState(7);
  const [sales, setSales] = useState<Sale[]>([]);

  useEffect(() => {
    gql<{ sales: Sale[] }>(QUERY, { from: addDays(todayStr(), -(days - 1)) })
      .then((d) => setSales(d.sales));
  }, [days]);

  const total = sales.reduce((s, x) => s + x.total, 0);

  return (
    <>
      <div className="page-head">
        <h1>Sales</h1><div className="grow" />
        <div className="chip-row">
          {[[1, 'Today'], [7, '7 days'], [30, '30 days']].map(([d, label]) => (
            <button key={d} className={`chip ${days === d ? 'active' : ''}`}
              onClick={() => setDays(d as number)}>{label}</button>
          ))}
        </div>
      </div>
      <div className="card">
        <table className="list">
          <thead><tr>
            <th>When</th><th>Client</th><th>Items</th><th>Method</th>
            <th className="num">Tip</th><th className="num">Total</th>
          </tr></thead>
          <tbody>
            {sales.map((s) => (
              <tr key={s.id}>
                <td className="fainttext">{fmtDateShort(s.createdAt)} · {s.createdAt.slice(11, 16)}</td>
                <td><b>{s.client.firstName} {s.client.lastName}</b></td>
                <td>{s.items.map((i) => i.description).join(', ')}</td>
                <td><Icon name={s.paymentMethod === 'cash' ? 'banknote' : 'card'} size={15} />{' '}
                  {s.paymentMethod === 'cash' ? 'Cash' : 'Card'}</td>
                <td className="num">{fmtMoney(s.tip)}</td>
                <td className="num"><b>{fmtMoney(s.total)}</b></td>
              </tr>
            ))}
            {sales.length === 0 && <tr><td colSpan={6} className="empty">No sales in this period</td></tr>}
            {sales.length > 0 && (
              <tr>
                <td colSpan={5} className="num"><b>{sales.length} sales</b></td>
                <td className="num"><b>{fmtMoney(total)}</b></td>
              </tr>
            )}
          </tbody>
        </table>
      </div>
    </>
  );
}
