// Light/dark theme with per-app defaults (dashboard: light, marketplace: dark)
// persisted in localStorage. The whole design system is CSS-token based, so
// switching is just a body class.
import { useEffect, useState } from 'react';

export type Theme = 'light' | 'dark';

export function useTheme(storageKey: string, defaultTheme: Theme) {
  const [theme, setTheme] = useState<Theme>(() => {
    // ?theme=light|dark overrides (used by screenshot verification)
    const fromUrl = new URLSearchParams(window.location.search).get('theme');
    if (fromUrl === 'light' || fromUrl === 'dark') return fromUrl;
    const saved = localStorage.getItem(storageKey);
    return saved === 'light' || saved === 'dark' ? saved : defaultTheme;
  });

  useEffect(() => {
    document.body.className = theme;
    localStorage.setItem(storageKey, theme);
  }, [theme, storageKey]);

  return { theme, toggle: () => setTheme((t) => (t === 'light' ? 'dark' : 'light')) };
}
