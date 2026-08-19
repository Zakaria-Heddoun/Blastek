// Lucide-style stroke icons, inlined so the app works offline.
// The 4-point sparkle is the brand mark — filled, single tone, used sparingly.

const PATHS: Record<string, string> = {
  calendar: 'M8 2v4 M16 2v4 M3 10h18 M5 4h14a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V6a2 2 0 0 1 2-2z',
  user: 'M19 21v-2a4 4 0 0 0-4-4H9a4 4 0 0 0-4 4v2 M16 7a4 4 0 1 1-8 0 4 4 0 0 1 8 0z',
  users: 'M16 21v-2a4 4 0 0 0-4-4H6a4 4 0 0 0-4 4v2 M13 7a4 4 0 1 1-8 0 4 4 0 0 1 8 0z M22 21v-2a4 4 0 0 0-3-3.87 M16 3.13a4 4 0 0 1 0 7.75',
  scissors: 'M9 6a3 3 0 1 1-6 0 3 3 0 0 1 6 0z M8.12 8.12 12 12 M20 4 8.12 15.88 M9 18a3 3 0 1 1-6 0 3 3 0 0 1 6 0z M14.8 14.8 20 20',
  card: 'M4 5h16a2 2 0 0 1 2 2v10a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V7a2 2 0 0 1 2-2z M2 10h20',
  banknote: 'M4 6h16a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2z M14 12a2 2 0 1 1-4 0 2 2 0 0 1 4 0z M6 12h.01 M18 12h.01',
  chart: 'M3 3v16a2 2 0 0 0 2 2h16 M18 17V9 M13 17V5 M8 17v-3',
  plus: 'M5 12h14 M12 5v14',
  check: 'M20 6 9 17l-5-5',
  star: 'm12 2 3.1 6.3 6.9 1-5 4.8 1.2 6.9-6.2-3.2-6.2 3.2L7 14.1l-5-4.8 6.9-1z',
  alert: 'm21.73 18-8-14a2 2 0 0 0-3.48 0l-8 14A2 2 0 0 0 4 21h16a2 2 0 0 0 1.73-3z M12 9v4 M12 17h.01',
  left: 'm15 18-6-6 6-6',
  right: 'm9 18 6-6-6-6',
  external: 'M15 3h6v6 M10 14 21 3 M18 13v6a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h6',
  search: 'M11 19a8 8 0 1 1 0-16 8 8 0 0 1 0 16z M21 21l-4.35-4.35',
  pin: 'M20 10c0 6-8 12-8 12s-8-6-8-12a8 8 0 0 1 16 0z M12 12a2.5 2.5 0 1 1 0-5 2.5 2.5 0 0 1 0 5z',
  clock: 'M12 21a9 9 0 1 1 0-18 9 9 0 0 1 0 18z M12 7v5l3 2',
  camera: 'M14.5 4 16 7h3a2 2 0 0 1 2 2v9a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V9a2 2 0 0 1 2-2h3l1.5-3h5z M16 13a4 4 0 1 1-8 0 4 4 0 0 1 8 0z',
  bell: 'M18 8a6 6 0 0 0-12 0c0 7-3 7-3 9h18c0-2-3-2-3-9 M13.73 21a2 2 0 0 1-3.46 0',
  shield: 'M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10z M9 12l2 2 4-4',
  sun: 'M12 2v2 M12 20v2 M4.93 4.93l1.41 1.41 M17.66 17.66l1.41 1.41 M2 12h2 M20 12h2 M4.93 19.07l1.41-1.41 M17.66 6.34l1.41-1.41 M16 12a4 4 0 1 1-8 0 4 4 0 0 1 8 0z',
  moon: 'M12 3a6 6 0 0 0 9 9 9 9 0 1 1-9-9z',
  globe: 'M12 21a9 9 0 1 1 0-18 9 9 0 0 1 0 18z M3.6 9h16.8 M3.6 15h16.8 M12 3a14 14 0 0 1 0 18 14 14 0 0 1 0-18z',
  // Marks a venue's answer under a review, so the two are read as a
  // conversation rather than as two opinions of equal standing.
  reply: 'M15 10 20 15 15 20 M4 4v7a4 4 0 0 0 4 4h12',
  flag: 'M4 15s1-1 4-1 5 2 8 2 4-1 4-1V3s-1 1-4 1-5-2-8-2-4 1-4 1z M4 22v-7',
  menu: 'M4 6h16 M4 12h16 M4 18h16',
  close: 'M18 6 6 18 M6 6l12 12',
};

export function Icon({ name, size = 20 }: { name: string; size?: number }) {
  return (
    <svg
      className="ic" width={size} height={size} viewBox="0 0 24 24" fill="none"
      stroke="currentColor" strokeWidth={1.75} strokeLinecap="round" strokeLinejoin="round"
      aria-hidden="true"
    >
      <path d={PATHS[name] ?? ''} />
    </svg>
  );
}

export function Sparkle({ size = 18 }: { size?: number }) {
  return (
    <svg className="ic spark" width={size} height={size} viewBox="0 0 24 24" fill="currentColor" aria-hidden="true">
      <path d="M12 1c.9 6.4 4.4 9.9 11 11-6.6 1.1-10.1 4.6-11 11-.9-6.4-4.4-9.9-11-11 6.6-1.1 10.1-4.6 11-11z" />
    </svg>
  );
}

/**
 * Filled stars read as a score at a glance; outlines read as a form control.
 *
 * `label` rather than an invented sentence: this is a leaf with no `t` in
 * scope, and a component that writes its own English is a component whose
 * screen-reader text nobody notices is untranslated. The numeric fallback is
 * language-neutral.
 */
export function StarRow({
  rating,
  size = 13,
  label,
}: {
  rating: number;
  size?: number;
  label?: string;
}) {
  const filled = Math.round(rating);

  return (
    <span className="stars" role="img" aria-label={label ?? `${rating.toFixed(1)}/5`}>
      {[0, 1, 2, 3, 4].map((i) => (
        <svg
          key={i}
          className="ic"
          width={size}
          height={size}
          viewBox="0 0 24 24"
          fill="currentColor"
          style={i < filled ? undefined : { opacity: 0.22 }}
          aria-hidden="true"
        >
          <path d={PATHS.star} />
        </svg>
      ))}
    </span>
  );
}
