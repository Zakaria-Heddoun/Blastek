// Infinite marquee (adapted from 21st.dev "Testimonials with Marquee" by serafim):
// two identical CSS-animated tracks for a seamless loop, paused on hover,
// alpha-masked edges. Pure CSS animation — no JS on the hot path.
import type { CSSProperties, ReactNode } from 'react';

export function Marquee({ children, duration = 40 }: { children: ReactNode; duration?: number }) {
  return (
    <div className="marquee" style={{ '--duration': `${duration}s` } as CSSProperties}>
      <div className="marquee-track">{children}</div>
      <div className="marquee-track" aria-hidden>{children}</div>
    </div>
  );
}
