// The salon's own view of its reviews (E10-T4 / F0.8).
//
// Two actions and no others: reply, and report. That is deliberate — there is
// no "delete", because a venue that can remove its own bad reviews has a
// rating that means nothing, and the whole of F0.8 rests on the rating meaning
// something. Reporting hands the decision to a platform admin and leaves the
// review up in the meantime.
//
// The reply is what this page is actually for. A calm answer under a complaint
// is read by every future customer who scrolls past it, and is worth more to
// the salon than the review's removal would have been.
import { useCallback, useEffect, useState } from 'react';
import { useTranslation } from 'react-i18next';
import { gql } from '../lib/gql';
import { Icon, StarRow } from '../lib/icons';
import { Modal, useToast } from '../components/ui';
import type { Review } from '../lib/types';
import { dirOf, fmtDateShort, initials } from '../lib/format';

const REVIEWS = `query($limit: Int, $offset: Int) {
  venueReviews(limit: $limit, offset: $offset) {
    totalCount
    items { id clientName rating comment createdAt reply replyAt status locale replyEditable }
  }
}`;

const REPLY = `mutation($id: ID!, $text: String!) {
  replyToReview(id: $id, text: $text) { id reply replyAt replyEditable }
}`;

const FLAG = `mutation($id: ID!, $reason: String) {
  flagReview(id: $id, reason: $reason) { id status }
}`;

// The categories a platform admin moderates against. Free text here would be
// the owner arguing their case; a category is what the queue can be sorted by.
const REASONS = ['abusive', 'spam', 'off_topic', 'personal_data'] as const;

export default function ReviewsPage() {
  const { t } = useTranslation();
  const toast = useToast();

  const [reviews, setReviews] = useState<Review[] | null>(null);
  const [rating, setRating] = useState(0);
  const [count, setCount] = useState(0);
  const [replying, setReplying] = useState<Review | null>(null);
  const [text, setText] = useState('');
  const [flagging, setFlagging] = useState<Review | null>(null);
  const [busy, setBusy] = useState(false);

  const load = useCallback(() => {
    gql<{ venueReviews: { totalCount: number; items: Review[] } }>(REVIEWS, { limit: 100 })
      .then((d) => {
        const items = d.venueReviews.items;
        setReviews(items);
        setCount(d.venueReviews.totalCount);
        // The headline average is computed from what is on screen rather than
        // read from the venue: this list is the venue's whole public record
        // (capped at 100), and one number sourced two ways is one that can
        // disagree with itself.
        setRating(items.length === 0 ? 0
          : items.reduce((sum, r) => sum + r.rating, 0) / items.length);
      })
      .catch(() => setReviews([]));
  }, []);

  useEffect(() => {
    document.title = `Blastek — ${t('admin.nav.reviews')}`;
    load();
  }, [load, t]);

  const sendReply = async () => {
    if (!replying || busy) return;
    setBusy(true);

    try {
      await gql(REPLY, { id: replying.id, text: text.trim() });
      toast(t('admin.reviews.replySaved'));
      setReplying(null);
      load();
    } catch (e) {
      toast((e as Error).message, true);
    } finally {
      setBusy(false);
    }
  };

  const sendFlag = async (reason: string) => {
    if (!flagging || busy) return;
    setBusy(true);

    try {
      await gql(FLAG, { id: flagging.id, reason });
      toast(t('admin.reviews.flagged'));
      setFlagging(null);
      load();
    } catch (e) {
      toast((e as Error).message, true);
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="adm-page">
      <div className="adm-head">
        <h1>{t('admin.nav.reviews')}</h1>
        {count > 0 && (
          <div className="adm-rating">
            <b>{rating.toFixed(1)}</b>
            <StarRow rating={rating} size={14} />
            <span className="fainttext">{t('admin.reviews.count', { count })}</span>
          </div>
        )}
      </div>

      {reviews === null ? (
        <div className="empty">{t('common.loading')}</div>
      ) : reviews.length === 0 ? (
        <div className="empty">{t('admin.reviews.none')}</div>
      ) : (
        <div className="adm-reviews">
          {reviews.map((r) => (
            <div key={r.id} className="card adm-review">
              <div className="who">
                <span className="avatar sm">{initials(r.clientName)}</span>
                <div className="grow">
                  <b>{r.clientName}</b>
                  <div className="fainttext">
                    {r.createdAt ? fmtDateShort(r.createdAt) : ''}
                    {r.status === 'flagged' && ` · ${t('admin.reviews.underReview')}`}
                  </div>
                </div>
                <StarRow rating={r.rating} size={13} />
              </div>

              {r.comment && (
                <div className="mutetext" dir={dirOf(r.locale)}>{r.comment}</div>
              )}

              {r.reply && (
                <div className="review-reply" dir={dirOf(r.locale)}>
                  <div className="review-reply-head">
                    <Icon name="reply" size={13} />
                    <b>{t('admin.reviews.yourReply')}</b>
                  </div>
                  <div className="mutetext">{r.reply}</div>
                </div>
              )}

              <div className="adm-review-actions">
                {/* Once the 48-hour window has closed the button goes away
                    rather than failing on submit — the server enforces it
                    either way, and being told after typing is the worse
                    version of the same rule. */}
                {(r.replyEditable ?? true) && (
                  <button
                    className="btn btn-sm"
                    onClick={() => { setText(r.reply ?? ''); setReplying(r); }}
                  >
                    {r.reply ? t('admin.reviews.editReply') : t('admin.reviews.reply')}
                  </button>
                )}

                {r.status !== 'flagged' && (
                  <button className="btn btn-sm btn-ghost" onClick={() => setFlagging(r)}>
                    <Icon name="flag" size={13} /> {t('admin.reviews.report')}
                  </button>
                )}
              </div>
            </div>
          ))}
        </div>
      )}

      {replying && (
        <Modal onClose={() => setReplying(null)}>
          <h3 style={{ marginTop: 0 }}>{t('admin.reviews.replyTitle')}</h3>
          <p className="mutetext" dir={dirOf(replying.locale)}>{replying.comment}</p>
          <textarea
            className="input"
            rows={5}
            value={text}
            maxLength={2000}
            aria-label={t('admin.reviews.replyLabel')}
            placeholder={t('admin.reviews.replyPlaceholder')}
            onChange={(e) => setText(e.target.value)}
          />
          <div className="fainttext" style={{ marginBottom: 12 }}>
            {t('admin.reviews.replyHint')}
          </div>
          <button className="btn btn-primary block" disabled={!text.trim() || busy} onClick={sendReply}>
            {busy ? t('common.saving') : t('admin.reviews.publishReply')}
          </button>
        </Modal>
      )}

      {flagging && (
        <Modal onClose={() => setFlagging(null)}>
          <h3 style={{ marginTop: 0 }}>{t('admin.reviews.reportTitle')}</h3>
          <p className="mutetext">{t('admin.reviews.reportLead')}</p>
          <div className="reason-list">
            {REASONS.map((reason) => (
              <button
                key={reason}
                className="btn block"
                disabled={busy}
                onClick={() => sendFlag(reason)}
              >
                {t(`admin.reviews.reasons.${reason}`)}
              </button>
            ))}
          </div>
        </Modal>
      )}
    </div>
  );
}
