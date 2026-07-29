// Sales: transaction ledger with quick date ranges.
import { useCallback, useEffect, useState } from 'react';
import { gql } from '../lib/gql';
import type { Sale } from '../lib/types';
import { Icon } from '../lib/icons';
import { addDays, fmtDateShort, fmtMAD, todayStr } from '../lib/format';
import Pager, { PAGE_SIZE } from '../components/Pager';

const QUERY = `query($from: Date!, $limit: Int, $offset: Int) {
  sales(from: $from, limit: $limit, offset: $offset) {
    totalCount
    items {
      id tipCents totalCents paymentMethod createdAt
      client { firstName lastName }
      items { id description }
    }
  }
}`;

export default function SalesPage() {
  const [days, setDays] = useState(7);
  const [sales, setSales] = useState<Sale[]>([]);
  const [total, setTotal] = useState(0);
  const [offset, setOffset] = useState(0);

  const from = addDays(todayStr(), -(days - 1));

  const load = useCallback(async (at: number) => {
    const d = await gql<{ sales: { items: Sale[]; totalCount: number } }>(
      QUERY, { from, limit: PAGE_SIZE, offset: at });
    setSales(d.sales.items);
    setTotal(d.sales.totalCount);
  }, [from]);

  // Changing the range resets to the first page.
  useEffect(() => { setOffset(0); load(0); }, [load]);

  const goTo = (next: number) => { setOffset(next); load(next); };

  // Sums the rows on screen — the period total lives in Reports, and adding
  // up one page and calling it the total would be wrong.
  const pageTotal = sales.reduce((s, x) => s + x.totalCents, 0);

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
                <td className="num">{fmtMAD(s.tipCents)}</td>
                <td className="num"><b>{fmtMAD(s.totalCents)}</b></td>
              </tr>
            ))}
            {sales.length === 0 && <tr><td colSpan={6} className="empty">No sales in this period</td></tr>}
            {sales.length > 0 && (
              <tr>
                <td colSpan={5} className="num">
                  <b>{total} sale{total === 1 ? '' : 's'} in this period</b>
                  {total > sales.length && <span className="fainttext"> · this page</span>}
                </td>
                <td className="num"><b>{fmtMAD(pageTotal)}</b></td>
              </tr>
            )}
          </tbody>
        </table>
        <Pager offset={offset} limit={PAGE_SIZE} totalCount={total} onChange={goTo} />
      </div>
    </>
  );
}
