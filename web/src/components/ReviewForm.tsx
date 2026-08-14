// Writing a review (E10-T4 / F0.8).
//
// Two places need this and they arrive from opposite directions: the account
// page, where somebody is already signed in and browsing their past visits,
// and the signed link from WhatsApp, where somebody tapped a message and has no
// session at all. The form is identical either way — a rating, an optional
// comment, one button — so the difference lives entirely in the `submit`
// function each caller hands over.
//
// The rating is required and the comment is not. F0.8 says so explicitly, and
// it is the right way round: a star is one tap and answers the question the
// salon actually asked, while insisting on prose is how a review request turns
// into a task and gets ignored.
import { useState } from 'react';
import { useTranslation } from 'react-i18next';
import { Icon } from '../lib/icons';

export default function ReviewForm({
  onSubmit,
  submitting = false,
}: {
  /** Throws to report an error; the caller owns what happens on success. */
  onSubmit: (rating: number, comment: string) => Promise<void>;
  submitting?: boolean;
}) {
  const { t } = useTranslation();
  const [rating, setRating] = useState(0);
  const [hover, setHover] = useState(0);
  const [comment, setComment] = useState('');
  const [busy, setBusy] = useState(false);

  const pending = busy || submitting;
  // What the row shows: the star being pointed at, or the one chosen.
  const shown = hover || rating;

  const send = async () => {
    if (rating === 0 || pending) return;
    setBusy(true);
    try {
      await onSubmit(rating, comment.trim());
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="review-form">
      <div
        className="star-picker"
        role="radiogroup"
        aria-label={t('review.ratingLabel')}
        onMouseLeave={() => setHover(0)}
      >
        {[1, 2, 3, 4, 5].map((n) => (
          <button
            key={n}
            type="button"
            role="radio"
            aria-checked={rating === n}
            // Named individually rather than "star 3 of 5": a screen reader
            // user picking a rating wants the word, not the arithmetic.
            aria-label={t(`review.stars.${n}`)}
            className={`star-btn ${n <= shown ? 'on' : ''}`}
            onMouseEnter={() => setHover(n)}
            onFocus={() => setHover(n)}
            onBlur={() => setHover(0)}
            onClick={() => setRating(n)}
          >
            <Icon name="star" size={30} />
          </button>
        ))}
      </div>

      {/* The chosen word, so the scale is not left to the reader to infer. */}
      <div className="star-caption">{shown ? t(`review.stars.${shown}`) : t('review.pickStars')}</div>

      <textarea
        className="input"
        rows={4}
        value={comment}
        maxLength={2000}
        placeholder={t('review.commentPlaceholder')}
        aria-label={t('review.commentLabel')}
        onChange={(e) => setComment(e.target.value)}
      />

      <button className="btn btn-primary block" disabled={rating === 0 || pending} onClick={send}>
        {pending ? t('common.saving') : t('review.submit')}
      </button>
    </div>
  );
}
