// Reports: stat tiles, single-series daily revenue bars, top services/staff.
import { useEffect, useRef, useState } from 'react';
import { gql } from '../lib/gql';
import type { ReportSummary } from '../lib/types';
import { addDays, fmtDateShort, fmtMAD, todayStr } from '../lib/format';

const QUERY = `query($days: Int) {
  reportSummary(days: $days) {
    days revenueCents tipsCents salesCount newClients
    appointments { completed noShows cancelled online total }
    revenueByDay { day revenueCents }
    topServices { name count revenueCents }
    topStaff { name color count revenueCents }
  }
}`;

export default function ReportsPage() {
  const [days, setDays] = useState(30);
  const [r, setR] = useState<ReportSummary | null>(null);
  const [tip, setTip] = useState<{ x: number; y: number; text: string } | null>(null);
  const wrapRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    gql<{ reportSummary: ReportSummary }>(QUERY, { days }).then((d) => setR(d.reportSummary));
  }, [days]);

  if (!r) return <div className="empty">Loading…</div>;

  const noShowRate = r.appointments.total
    ? Math.round((r.appointments.noShows / r.appointments.total) * 100) : 0;
  const onlineShare = r.appointments.total
    ? Math.round((r.appointments.online / r.appointments.total) * 100) : 0;

  const byDay = new Map(r.revenueByDay.map((d) => [d.day, d.revenueCents]));
  const series = [...Array(days)].map((_, i) => {
    const day = addDays(todayStr(), -(days - 1 - i));
    return { day, revenueCents: byDay.get(day) ?? 0 };
  });
  const max = Math.max(...series.map((s) => s.revenueCents), 1);
  const labelEvery = Math.ceil(days / 8);

  return (
    <>
      <div className="page-head">
        <h1>Reports</h1><div className="grow" />
        <div className="chip-row">
          {[7, 30, 90].map((d) => (
            <button key={d} className={`chip ${days === d ? 'active' : ''}`} onClick={() => setDays(d)}>
              {d} days
            </button>
          ))}
        </div>
      </div>
      <div className="tiles">
        <div className="card tile"><div className="v">{fmtMAD(r.revenueCents)}</div><div className="l">Revenue</div></div>
        <div className="card tile"><div className="v">{r.salesCount}</div><div className="l">Sales</div></div>
        <div className="card tile"><div className="v">{fmtMAD(r.tipsCents)}</div><div className="l">Tips collected</div></div>
        <div className="card tile"><div className="v">{r.appointments.completed}</div><div className="l">Appointments completed</div></div>
        <div className="card tile"><div className="v">{noShowRate}%</div><div className="l">No-show rate</div></div>
        <div className="card tile"><div className="v">{onlineShare}%</div><div className="l">Booked online</div></div>
      </div>
      <div className="card pad">
        <h2 style={{ fontSize: 16, marginBottom: 14 }}>Daily revenue — last {days} days</h2>
        <div className="chart-wrap" style={{ paddingLeft: 44 }} ref={wrapRef}>
          <div style={{ position: 'relative' }}>
            {[0.25, 0.5, 0.75, 1].map((g) => (
              <div key={g} className="gridline" style={{ bottom: g * 180 }}>
                <span className="gl">{fmtMAD(Math.round(max * g))}</span>
              </div>
            ))}
            <div className="bars">
              {series.map((s, i) => (
                <div key={s.day} className="bar-slot"
                  onMouseEnter={(e) => {
                    const sr = e.currentTarget.getBoundingClientRect();
                    const wr = wrapRef.current!.getBoundingClientRect();
                    setTip({
                      x: sr.left - wr.left + sr.width / 2, y: sr.top - wr.top,
                      text: `${fmtDateShort(s.day)} · ${fmtMAD(s.revenueCents)}`,
                    });
                  }}
                  onMouseLeave={() => setTip(null)}>
                  <div className="bar" style={{
                    height: `${Math.max((s.revenueCents / max) * 100, s.revenueCents ? 2 : 0.5)}%`,
                  }} />
                </div>
              ))}
            </div>
          </div>
          <div className="x-labels">
            {series.map((s, i) => (
              <span key={s.day}>{i % labelEvery === 0 ? s.day.slice(5).replace('-', '/') : ''}</span>
            ))}
          </div>
          {tip && (
            <div className="chart-tip" style={{ display: 'block', left: tip.x, top: tip.y }}>{tip.text}</div>
          )}
        </div>
      </div>
      <div className="two-col">
        <div className="card">
          <div className="pad" style={{ paddingBottom: 0 }}><h2 style={{ fontSize: 16 }}>Top services</h2></div>
          <table className="list">
            <thead><tr><th>Service</th><th className="num">Sold</th><th className="num">Revenue</th></tr></thead>
            <tbody>
              {r.topServices.map((s) => (
                <tr key={s.name}><td>{s.name}</td>
                  <td className="num">{s.count}</td><td className="num"><b>{fmtMAD(s.revenueCents)}</b></td></tr>
              ))}
            </tbody>
          </table>
        </div>
        <div className="card">
          <div className="pad" style={{ paddingBottom: 0 }}><h2 style={{ fontSize: 16 }}>Team performance</h2></div>
          <table className="list">
            <thead><tr><th>Team member</th><th className="num">Completed</th><th className="num">Revenue</th></tr></thead>
            <tbody>
              {r.topStaff.map((s) => (
                <tr key={s.name}>
                  <td><span className="dot" style={{ background: s.color, marginRight: 7 }} />{s.name}</td>
                  <td className="num">{s.count}</td><td className="num"><b>{fmtMAD(s.revenueCents)}</b></td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </div>
    </>
  );
}
