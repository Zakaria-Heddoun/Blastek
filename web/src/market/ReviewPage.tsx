// The page a review invite links to (E10-T3, E10-T4 / F0.8).
//
// Reached from WhatsApp, on a phone, by somebody who is very likely not signed
// in — so this page never asks them to be. The token in the URL is the
// credential: `reviewInvitation` resolves it to the visit, and
// `createReviewFromLink` writes the review against the same token.
//
// It loads *before* asking for anything. A link that has expired, or a booking
// already reviewed, is answered with a sentence on the page rather than with a
// form that fails on submit — somebody who has just typed two paragraphs about
// their haircut should not be the one to discover the link was stale.
import { useEffect, useState } from 'react';
import { Link, useParams } from 'react-router-dom';
import { useTranslation } from 'react-i18next';
import { gql } from '../lib/gql';
import ReviewForm from '../components/ReviewForm';
import MarketTopbar from './MarketTopbar';
import { fmtDateLong } from '../lib/format';
import './market.css';

const INVITATION = `query($token: String!) {
  reviewInvitation(token: $token) {
    bookingRef venueName venueSlug serviceName date error
  }
}`;

const CREATE = `mutation($token: String!, $rating: Int!, $comment: String) {
  createReviewFromLink(token: $token, rating: $rating, comment: $comment) { id rating }
}`;

interface Invitation {
  bookingRef: string | null;
  venueName: string | null;
  venueSlug: string | null;
  serviceName: string | null;
  date: string | null;
  error: string | null;
}

export default function ReviewPage() {
  const { token = '' } = useParams();
  const { t } = useTranslation();
  const [invitation, setInvitation] = useState<Invitation | null>(null);
  const [loading, setLoading] = useState(true);
  const [done, setDone] = useState(false);
  const [error, setError] = useState('');

  useEffect(() => {
    document.title = `Blastek — ${t('review.pageTitle')}`;

    gql<{ reviewInvitation: Invitation }>(INVITATION, { token })
      .then((d) => setInvitation(d.reviewInvitation))
      // A network failure and a bad token look the same to the reader, and the
      // useful thing to say is the same too.
      .catch(() => setInvitation({ ...blank, error: t('review.linkInvalid') }))
      .finally(() => setLoading(false));
  }, [token, t]);

  const submit = async (rating: number, comment: string) => {
    try {
      await gql(CREATE, { token, rating, comment });
      setDone(true);
    } catch (e) {
      setError((e as Error).message);
      throw e;
    }
  };

  const venueLink = invitation?.venueSlug ? `/v/${invitation.venueSlug}` : '/venues';

  return (
    // `mkt` scopes the marketplace stylesheet; without it this page renders
    // as unstyled HTML, which is exactly what a customer arriving from a
    // message must not meet.
    <div className="mkt">
      <MarketTopbar />
      <div className="bk-shell" style={{ paddingTop: 24, paddingBottom: 60, maxWidth: 560 }}>
        {loading ? (
          <div className="empty">{t('common.loading')}</div>
        ) : done ? (
          <div className="card review-done">
            <h1 className="section-title" style={{ marginTop: 0 }}>{t('review.thanksTitle')}</h1>
            <p className="mutetext">{t('review.thanksBody')}</p>
            <Link className="btn" to={venueLink}>{t('review.backToVenue')}</Link>
          </div>
        ) : invitation?.error ? (
          <div className="card review-done">
            <h1 className="section-title" style={{ marginTop: 0 }}>{t('review.cannotTitle')}</h1>
            <p className="mutetext">{invitation.error}</p>
            <Link className="btn" to={venueLink}>{t('review.backToVenue')}</Link>
          </div>
        ) : (
          <div className="card">
            <h1 className="section-title" style={{ marginTop: 0 }}>
              {t('review.howWasIt', { venue: invitation?.venueName ?? '' })}
            </h1>
            <p className="mutetext">
              {invitation?.serviceName}
              {invitation?.date ? ` · ${fmtDateLong(invitation.date)}` : ''}
            </p>

            {error && <div className="formerror">{error}</div>}
            <ReviewForm onSubmit={submit} />
          </div>
        )}
      </div>
    </div>
  );
}

const blank: Invitation = {
  bookingRef: null,
  venueName: null,
  venueSlug: null,
  serviceName: null,
  date: null,
  error: null,
};
