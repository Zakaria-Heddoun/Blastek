// Who is away, and when (E9-T2 / F0.7).
//
// The calendar shows a block on the day it falls; this answers the question
// the calendar cannot — "is anyone off next month?" — which is the one an
// owner asks before promising a customer a date.
import { useCallback, useEffect, useState } from 'react';
import { useTranslation } from 'react-i18next';
import { gql } from '../lib/gql';
import { useToast } from '../components/ui';
import { addDays, fmtDateLong, fmtTime, todayStr, weekdaysFull } from '../lib/format';
import { BLOCK_FIELDS, type StaffBlock } from './StaffBlocks';
import { useAppData } from './AdminLayout';

// Far enough ahead to cover a season's holidays without listing forever.
const HORIZON_DAYS = 120;

export default function TimeOffTab() {
  const { t } = useTranslation();
  const { staff } = useAppData();
  const toast = useToast();
  const [blocks, setBlocks] = useState<StaffBlock[] | null>(null);

  const load = useCallback(async () => {
    const d = await gql<{ staffBlocks: StaffBlock[] }>(
      `query($from: Date!, $to: Date!) { staffBlocks(from: $from, to: $to) { ${BLOCK_FIELDS} } }`,
      { from: todayStr(), to: addDays(todayStr(), HORIZON_DAYS) },
    );
    setBlocks(d.staffBlocks ?? []);
  }, []);

  useEffect(() => { load(); }, [load]);

  const remove = async (id: string) => {
    try {
      await gql('mutation($id: ID!) { deleteStaffBlock(id: $id) }', { id });
      toast(t('common.saved'));
      load();
    } catch (e) {
      toast((e as Error).message, true);
    }
  };

  const nameOf = (staffId: string) => staff.find((s) => s.id === staffId)?.name ?? '';
  const weekdays = weekdaysFull();

  const when = (b: StaffBlock) => {
    // A weekly rule has no single date to print, so it says which day instead.
    if (b.weekly && b.weekday != null) {
      return `${t('admin.team.everyWeek', { day: weekdays[b.weekday] })} · ${fmtTime(b.startMin ?? 0)}–${fmtTime(b.endMin ?? 0)}`;
    }

    const days = b.endDate && b.endDate !== b.date
      ? `${fmtDateLong(b.date)} – ${fmtDateLong(b.endDate)}`
      : fmtDateLong(b.date);

    if (b.startMin == null || b.endMin == null) return days;
    return `${days} · ${fmtTime(b.startMin)}–${fmtTime(b.endMin)}`;
  };

  if (blocks === null) return <div className="empty">{t('common.loading')}</div>;

  return (
    <div className="card">
      <table className="list">
        <thead>
          <tr>
            <th>{t('admin.calendar.teamMember')}</th>
            <th>{t('admin.calendar.blockKindLabel')}</th>
            <th>{t('common.date')}</th>
            <th>{t('admin.schedule.reason')}</th>
            <th></th>
          </tr>
        </thead>
        <tbody>
          {blocks.map((b) => (
            <tr key={b.id}>
              <td><b>{nameOf(b.staffId)}</b></td>
              <td>{t(`admin.calendar.blockKind.${b.kind}`)}</td>
              <td>{when(b)}</td>
              <td className="mutetext">{b.note}</td>
              <td className="num">
                <button className="btn btn-sm" onClick={() => remove(b.id)}>
                  {t('admin.team.removeBlock')}
                </button>
              </td>
            </tr>
          ))}
          {blocks.length === 0 && (
            <tr><td colSpan={5} className="empty">{t('admin.team.noTimeOff')}</td></tr>
          )}
        </tbody>
      </table>
    </div>
  );
}
