// Offset pager for the paginated dashboard lists (clients, sales).
// Hidden entirely when everything fits on one page, so small venues never see it.

export const PAGE_SIZE = 50;

export default function Pager({
  offset, limit, totalCount, onChange,
}: {
  offset: number;
  limit: number;
  totalCount: number;
  onChange: (offset: number) => void;
}) {
  if (totalCount <= limit) return null;

  const page = Math.floor(offset / limit) + 1;
  const pages = Math.ceil(totalCount / limit);
  const first = offset + 1;
  const last = Math.min(offset + limit, totalCount);

  return (
    <div className="pager">
      <span className="fainttext">
        {first}–{last} of {totalCount}
      </span>
      <div className="grow" />
      <button
        className="btn btn-sm"
        disabled={offset === 0}
        onClick={() => onChange(Math.max(0, offset - limit))}
      >
        Previous
      </button>
      <span className="fainttext">Page {page} of {pages}</span>
      <button
        className="btn btn-sm"
        disabled={last >= totalCount}
        onClick={() => onChange(offset + limit)}
      >
        Next
      </button>
    </div>
  );
}
