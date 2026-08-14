// "How did it go?" on the account page (E10-T4 / F0.8).
//
// The invite that matters is the WhatsApp one — it reaches somebody who is not
// thinking about the salon's website. This is the second chance: a customer who
// came back to look at their bookings is already here, and the visit they have
// not reviewed is worth one line at the top of the page.
//
// It renders nothing at all when there is nothing to ask about, which is the
// common case. A section header sitting above an empty box on every visit is
// how a prompt becomes furniture.
import { useCallback, useEffect, useState } from 'react';
import { useTranslation } from 'react-i18next';
import { gql } from '../lib/gql';
import { Modal, useToast } from '../components/ui';
import ReviewForm from '../components/ReviewForm';
import { fmtDateLong } from '../lib/format';

const REVIEWABLE = `{ myReviewableVisits { bookingRef venueName venueSlug serviceName date } }`;

const CREATE = `mutation($ref: String!, $rating: Int!, $comment: String) {
  createReview(bookingRef: $ref, rating: $rating, comment: $comment) { id }
}`;

interface Visit {
  bookingRef: string;
  venueName: string | null;
  venueSlug: string | null;
  serviceName: string | null;
  date: string | null;
}

export default function ReviewPrompts() {
  const { t } = useTranslation();
  const toast = useToast();
  const [visits, setVisits] = useState<Visit[]>([]);
  const [writing, setWriting] = useState<Visit | null>(null);
  const [error, setError] = useState('');

  const load = useCallback(() => {
    gql<{ myReviewableVisits: Visit[] }>(REVIEWABLE)
      .then((d) => setVisits(d.myReviewableVisits ?? []))
      // A prompt is an extra; failing to load one must not disturb the page it
      // sits on, which is the customer's actual appointments.
      .catch(() => setVisits([]));
  }, []);

  useEffect(load, [load]);

  const submit = async (rating: number, comment: string) => {
    if (!writing) return;

    try {
      await gql(CREATE, { ref: writing.bookingRef, rating, comment });
      setWriting(null);
      setError('');
      toast(t('review.thanksTitle'));
      load();
    } catch (e) {
      setError((e as Error).message);
      throw e;
    }
  };

  if (visits.length === 0) return null;

  return (
    <>
      <h2 className="section-title">{t('review.promptsTitle')}</h2>
      <div className="review-prompts">
        {visits.map((visit) => (
          <div key={visit.bookingRef} className="card review-prompt">
            <div className="grow">
              <b>{visit.venueName}</b>
              <div className="fainttext">
                {visit.serviceName}
                {visit.date ? ` · ${fmtDateLong(visit.date)}` : ''}
              </div>
            </div>
            <button className="btn btn-sm btn-primary" onClick={() => { setError(''); setWriting(visit); }}>
              {t('review.leaveOne')}
            </button>
          </div>
        ))}
      </div>

      {writing && (
        <Modal onClose={() => setWriting(null)}>
          <h3 style={{ marginTop: 0 }}>
            {t('review.howWasIt', { venue: writing.venueName ?? '' })}
          </h3>
          <p className="mutetext">
            {writing.serviceName}
            {writing.date ? ` · ${fmtDateLong(writing.date)}` : ''}
          </p>
          {error && <div className="formerror">{error}</div>}
          <ReviewForm onSubmit={submit} />
        </Modal>
      )}
    </>
  );
}
