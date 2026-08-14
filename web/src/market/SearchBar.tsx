// Marketplace search: one field for what you want, one for where.
// Both collapse into a single `q` on the API — venue name, city and address are
// searched together, so "barber rabat" and "rabat" both work.
import { useState } from 'react';
import { useTranslation } from 'react-i18next';
import { useNavigate } from 'react-router-dom';
import { Icon } from '../lib/icons';

export default function SearchBar({
  initialQ = '',
  initialWhere = '',
  variant = 'hero',
}: {
  initialQ?: string;
  initialWhere?: string;
  /** `hero` sits on the homepage; `inline` sits above results. */
  variant?: 'hero' | 'inline';
}) {
  const { t } = useTranslation();
  const navigate = useNavigate();
  const [q, setQ] = useState(initialQ);
  const [where, setWhere] = useState(initialWhere);

  const submit = (e: React.FormEvent) => {
    e.preventDefault();
    const params = new URLSearchParams();
    if (q.trim()) params.set('q', q.trim());
    if (where.trim()) params.set('where', where.trim());
    navigate(`/venues${params.toString() ? `?${params}` : ''}`);
  };

  return (
    <form className={`mkt-search mkt-search-${variant}`} onSubmit={submit} role="search">
      <label className="mkt-search-field">
        <span className="mkt-search-label">{t(`venues.searchPlaceholder`)}</span>
        <input
          value={q}
          onChange={(e) => setQ(e.target.value)}
          placeholder={t(`home.searchPlaceholder`)}
          aria-label={t(`venues.searchPlaceholder`)}
        />
      </label>

      <span className="mkt-search-divider" aria-hidden="true" />

      <label className="mkt-search-field">
        <span className="mkt-search-label">{t(`venues.wherePlaceholder`)}</span>
        <input
          value={where}
          onChange={(e) => setWhere(e.target.value)}
          placeholder={t(`home.wherePlaceholder`)}
          aria-label={t(`home.wherePlaceholder`)}
        />
      </label>

      <button className="mkt-search-go" type="submit" aria-label={t(`common.search`)}>
        <Icon name="search" size={18} />
      </button>
    </form>
  );
}
