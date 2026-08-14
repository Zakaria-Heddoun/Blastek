// Booking flow: 1 services → 2 professional → 3 time → 4 confirm → done.
import { useEffect, useMemo, useState } from 'react';
import type { ReactNode } from 'react';
import { Link, useNavigate } from 'react-router-dom';
import { useTranslation } from 'react-i18next';
import { gql } from '../lib/gql';
import type { BookingResult, Slot } from '../lib/types';
import { STEP_KEYS, useVenue } from './MarketLayout';
import { useAuth } from '../lib/auth';
import { Icon, Sparkle } from '../lib/icons';
import { addDays, fmtDateLong, fmtDateShort, fmtDur, fmtMAD, fmtTime, initials, todayStr, weekdaysShort } from '../lib/format';

export default function BookingFlow() {
  const { venue: v, slug, booking } = useVenue();
  const { t } = useTranslation();
  const { user } = useAuth();
  const navigate = useNavigate();
  const [step, setStep] = useState(1);
  const [date, setDate] = useState(booking.date || todayStr());
  const [slot, setSlot] = useState<Slot | null>(null);
  const [slots, setSlots] = useState<Slot[] | null>(null);
  const [notes, setNotes] = useState('');
  const [err, setErr] = useState('');
  const [result, setResult] = useState<BookingResult | null>(null);

  const selected = booking.services
    .map((id) => v.services.find((s) => s.id === id)!)
    .filter(Boolean);
  const totalPrice = selected.reduce((s, x) => s + x.priceCents, 0);
  const totalDur = selected.reduce((s, x) => s + x.durationMin, 0);

  const eligible = useMemo(() => v.staff.filter((st) =>
    booking.services.every((id) => st.serviceIds.includes(id))), [v.staff, booking.services]);

  const days = [...Array(14)].map((_, i) => addDays(todayStr(), i));
  const weekdayNames = weekdaysShort();

  useEffect(() => { window.scrollTo(0, 0); }, [step, result]);

  useEffect(() => {
    if (step !== 3 || booking.services.length === 0) return;
    setSlots(null);
    gql<{ availability: { slots: Slot[] } }>(
      `query($venue: String!, $ids: [ID!]!, $staff: String, $date: Date!) {
        availability(venueSlug: $venue, serviceIds: $ids, staffId: $staff, date: $date) {
          slots { startMin staffId } } }`,
      { venue: slug, ids: booking.services, staff: booking.staffId, date },
    ).then((d) => setSlots(d.availability.slots)).catch((e) => setErr(e.message));
  }, [step, date, slug, booking.services, booking.staffId]);

  const toggleService = (id: string) => {
    booking.setServices(booking.services.includes(id)
      ? booking.services.filter((x) => x !== id) : [...booking.services, id]);
    booking.setStaffId('any');
    setSlot(null);
  };

  const submit = async () => {
    try {
      const d = await gql<{ book: BookingResult }>(
        `mutation($venue: String!, $ids: [ID!]!, $staff: String, $date: Date!,
          $startMin: Int!, $notes: String) {
          book(venueSlug: $venue, serviceIds: $ids, staffId: $staff, date: $date,
            startMin: $startMin, notes: $notes) {
            bookingRef date startMin endMin staffName
            appointments { id priceCents service { name } }
          } }`,
        {
          venue: slug,
          ids: booking.services,
          staff: booking.staffId === 'any' ? String(slot!.staffId) : booking.staffId,
          date, startMin: slot!.startMin, notes,
        });
      setResult(d.book);
    } catch (e) {
      setErr((e as Error).message);
    }
  };

  if (result) {
    return (
      <div className="bk-shell confirm-hero sparkle-field">
        <div className="sparkmark"><Sparkle size={56} /></div>
        <h1>
          {t('flow.confirmedTitle', {
            date: fmtDateShort(result.date),
            time: fmtTime(result.startMin, true),
          })}
        </h1>
        <div className="mutetext">{t('flow.reference')} <b>{result.bookingRef}</b></div>
        {/* `text-align: start` rather than `left`: this card holds a right-to-left
            summary in Arabic. */}
        <div className="card pad" style={{ maxWidth: 420, margin: '22px auto', textAlign: 'start' }}>
          <div style={{ display: 'flex', justifyContent: 'space-between', padding: '6px 0' }}>
            <span className="mutetext">{t('flow.summaryWhen')}</span>
            <b>{fmtDateLong(result.date)}, {fmtTime(result.startMin, true)}</b>
          </div>
          <div style={{ display: 'flex', justifyContent: 'space-between', padding: '6px 0' }}>
            <span className="mutetext">{t('flow.summaryProfessional')}</span><b>{result.staffName}</b>
          </div>
          {result.appointments.map((a) => (
            <div key={a.id} style={{ display: 'flex', justifyContent: 'space-between', padding: '6px 0' }}>
              <span>{a.service.name}</span><b>{fmtMAD(a.priceCents)}</b>
            </div>
          ))}
        </div>
        <button className="btn btn-primary" style={{ padding: '11px 22px' }}
          onClick={() => { booking.setServices([]); setResult(null); setSlot(null); setStep(1); navigate('/'); }}>
          {t('flow.bookAnother')}
        </button>
      </div>
    );
  }

  const anyLabel = t('flow.anyProfessional');
  const staffName = booking.staffId === 'any'
    ? (slot ? v.staff.find((s) => s.id === slot.staffId)?.name ?? anyLabel : anyLabel)
    : v.staff.find((s) => s.id === booking.staffId)?.name ?? '';

  const summary = (cta: string, enabled: boolean, onCta: () => void, extra?: ReactNode) => (
    <div className="card summary-card">
      <b style={{ fontSize: 16 }}>{v.settings.businessName}</b>
      <div className="fainttext" style={{ marginBottom: 8 }}>
        <span className="stars"><Icon name="star" size={12} /></span> {v.rating} ({v.reviews.length}) ·{' '}
        {v.settings.businessAddress}
      </div>
      {selected.map((s) => (
        <div key={s.id} className="line">
          <span>{s.name}<br /><span className="fainttext">{fmtDur(s.durationMin)}</span></span>
          <b>{fmtMAD(s.priceCents)}</b>
        </div>
      ))}
      {selected.length === 0 && (
        <div className="fainttext" style={{ padding: '8px 0' }}>{t('flow.noServicesSelected')}</div>
      )}
      {extra}
      {selected.length > 0 && (
        <div className="line total">
          <span>{t('flow.totalWithDuration', { duration: fmtDur(totalDur) })}</span>
          <span>{fmtMAD(totalPrice)}</span>
        </div>
      )}
      <button className="btn btn-primary cta" disabled={!enabled} onClick={onCta}>{cta}</button>
    </div>
  );

  return (
    <>
      <div className="bk-steps bk-shell" style={{ paddingTop: 16 }}>
        {STEP_KEYS.map((key, i) => (
          <span key={key} style={{ display: 'contents' }}>
            <span className={`st ${step === i + 1 ? 'on' : ''}`}>{t(`flow.steps.${key}`)}</span>
            {i < STEP_KEYS.length - 1 && <span className="sep">›</span>}
          </span>
        ))}
      </div>
      <div className="bk-body">
        <div>
          {step === 1 && (
            <>
              <Link className="btn btn-ghost" to={`/v/${slug}`}>
                <Icon name="left" size={16} /> {v.settings.businessName}
              </Link>
              <h1 style={{ fontSize: 24, margin: '12px 0 6px' }}>{t('flow.selectServices')}</h1>
              {v.categories.map((c) => {
                const svcs = v.services.filter((s) => s.categoryId === c.id);
                if (!svcs.length) return null;
                return (
                  <div key={c.id}>
                    <h2 className="section-title">{c.name}</h2>
                    {svcs.map((s) => (
                      <div key={s.id} className={`svc-row ${booking.services.includes(s.id) ? 'sel' : ''}`}
                        onClick={() => toggleService(s.id)}>
                        <div className="grow">
                          <b>{s.name}</b>
                          <div className="fainttext">
                            {fmtDur(s.durationMin)}{s.description ? ` · ${s.description}` : ''}
                          </div>
                        </div>
                        <span className="price">{fmtMAD(s.priceCents)}</span>
                        <span className="pick">
                          <Icon name={booking.services.includes(s.id) ? 'check' : 'plus'} size={15} />
                        </span>
                      </div>
                    ))}
                  </div>
                );
              })}
            </>
          )}

          {step === 2 && (
            <>
              <button className="btn btn-ghost" onClick={() => setStep(1)}>
                <Icon name="left" size={16} /> {t('flow.steps.services')}
              </button>
              <h1 style={{ fontSize: 24, margin: '12px 0 18px' }}>{t('flow.chooseProfessional')}</h1>
              {eligible.length === 0 && (
                <div className="card pad" style={{ marginBottom: 14 }}>
                  {t('flow.noSingleProfessional')}
                </div>
              )}
              <div className="pro-grid">
                <div className={`pro-card ${booking.staffId === 'any' ? 'sel' : ''}`}
                  onClick={() => { booking.setStaffId('any'); setSlot(null); }}>
                  <div className="avatar" style={{ background: 'var(--brand-wine)', color: 'var(--brand-gold)' }}>
                    <Sparkle size={20} />
                  </div>
                  <b>{t('flow.anyProfessional')}</b>
                  <div className="fainttext">{t('flow.anyProfessionalHint')}</div>
                </div>
                {eligible.map((st) => (
                  <div key={st.id} className={`pro-card ${booking.staffId === st.id ? 'sel' : ''}`}
                    onClick={() => { booking.setStaffId(st.id); setSlot(null); }}>
                    <div className="avatar" style={{ background: st.color }}>{initials(st.name)}</div>
                    <b>{st.name}</b>
                    <div className="fainttext">{st.role}</div>
                  </div>
                ))}
              </div>
            </>
          )}

          {step === 3 && (
            <>
              <button className="btn btn-ghost" onClick={() => setStep(2)}>
                <Icon name="left" size={16} /> {t('flow.steps.professional')}
              </button>
              <h1 style={{ fontSize: 24, margin: '12px 0 18px' }}>{t('flow.pickTime')}</h1>
              <div className="date-strip">
                {days.map((d) => {
                  const dt = new Date(d + 'T12:00:00');
                  return (
                    <div key={d} className={`date-pill ${d === date ? 'sel' : ''}`}
                      onClick={() => { setDate(d); setSlot(null); }}>
                      <small>{weekdayNames[dt.getDay()]}</small>{dt.getDate()}
                    </div>
                  );
                })}
              </div>
              {slots === null ? (
                <div className="empty">{t('flow.loadingAvailability')}</div>
              ) : slots.length === 0 ? (
                <div className="empty">
                  {/* The suggestion only makes sense when a specific professional
                      was chosen, so it is a separate sentence rather than a
                      fragment glued on — which is unglueable in Arabic. */}
                  {booking.staffId !== 'any'
                    ? t('flow.noAvailabilityAny')
                    : t('flow.noAvailability')}
                </div>
              ) : (
                <div className="slot-grid">
                  {slots.map((s) => (
                    <div key={s.startMin} className={`slot ${slot?.startMin === s.startMin ? 'sel' : ''}`}
                      onClick={() => setSlot(s)}>
                      {fmtTime(s.startMin, true)}
                    </div>
                  ))}
                </div>
              )}
            </>
          )}

          {step === 4 && slot && (
            <>
              <button className="btn btn-ghost" onClick={() => setStep(3)}>
                <Icon name="left" size={16} /> {t('flow.steps.time')}
              </button>
              <h1 style={{ fontSize: 24, margin: '12px 0 6px' }}>{t('flow.reviewConfirm')}</h1>
              <div className="mutetext" style={{ marginBottom: 16 }}>
                {t('flow.atWith', {
                  date: fmtDateLong(date),
                  time: fmtTime(slot.startMin, true),
                  staff: staffName,
                })}
              </div>
              {user ? (
                <div className="card pad">
                  <div className="review-who" style={{ marginBottom: 4 }}>
                    <div className="avatar">{initials(`${user.firstName} ${user.lastName}`)}</div>
                    <div>
                      <b>
                        {t('flow.bookingAs', {
                          name: `${user.firstName} ${user.lastName}`.trim(),
                        })}
                      </b>
                      <div className="fainttext">{user.email}{user.phone ? ` · ${user.phone}` : ''}</div>
                    </div>
                  </div>
                  <label>{t('flow.notesLabel')}</label>
                  <textarea rows={2} placeholder={t('flow.notesPlaceholder')}
                    value={notes} onChange={(e) => setNotes(e.target.value)} />
                  <div className="err">{err}</div>
                </div>
              ) : (
                <div className="card pad" style={{ textAlign: 'center', padding: 32 }}>
                  <h2 style={{ fontSize: 17, marginBottom: 6 }}>{t('flow.signInTitle')}</h2>
                  <p className="mutetext" style={{ marginTop: 0 }}>{t('flow.signInBody')}</p>
                  <Link className="btn btn-accent" style={{ borderRadius: 999, padding: '10px 22px' }}
                    to={`/login?next=${encodeURIComponent(`/v/${slug}/flow`)}`}>
                    {t('flow.signInCta')}
                  </Link>
                </div>
              )}
            </>
          )}
        </div>
        <div>
          {step === 1 && summary(t('common.continue'), selected.length > 0, () => setStep(2))}
          {step === 2 && summary(t('common.continue'),
            eligible.length > 0 || booking.staffId === 'any', () => setStep(3))}
          {step === 3 && summary(t('common.continue'), !!slot, () => setStep(4), slot && (
            <div className="line">
              <span>{t('flow.summaryTime')}</span>
              <b>{fmtDateShort(date)}, {fmtTime(slot.startMin, true)}</b>
            </div>
          ))}
          {step === 4 && slot && summary(t('venue.bookNow'), !!user, submit, (
            <>
              <div className="line">
                <span>{t('flow.summaryTime')}</span>
                <b>{fmtDateShort(date)}, {fmtTime(slot.startMin, true)}</b>
              </div>
              <div className="line">
                <span>{t('flow.summaryProfessional')}</span><b>{staffName}</b>
              </div>
            </>
          ))}
        </div>
      </div>
    </>
  );
}
