// Picking a language (E7-T1 / F0.11).
//
// Two shapes, one behaviour. `inline` is three small buttons for a settings
// panel; the default is a dropdown for a navigation bar, where three languages
// would eat the space a "Book now" button needs.
//
// Each language is named in itself — "العربية", not "Arabic". A picker that
// labels languages in a language you cannot read is the one control on the page
// guaranteed to be useless to the person who needs it.
import { useEffect, useRef, useState } from 'react';
import { useTranslation } from 'react-i18next';
import { LOCALES, LOCALE_NAMES, type Locale } from '../lib/i18n';
import { useLocale } from '../lib/locale';
import { Icon } from '../lib/icons';
import './language-switcher.css';

export default function LanguageSwitcher({
  variant = 'menu',
  className = '',
}: {
  variant?: 'menu' | 'inline';
  className?: string;
}) {
  const { t } = useTranslation();
  const { locale, setLocale } = useLocale();
  const [open, setOpen] = useState(false);
  const root = useRef<HTMLDivElement>(null);

  // A menu that only closes on its own trigger is a menu that stays open.
  useEffect(() => {
    if (!open) return;

    const onPointerDown = (event: MouseEvent) => {
      if (!root.current?.contains(event.target as Node)) setOpen(false);
    };
    const onKeyDown = (event: KeyboardEvent) => {
      if (event.key === 'Escape') setOpen(false);
    };

    document.addEventListener('mousedown', onPointerDown);
    document.addEventListener('keydown', onKeyDown);
    return () => {
      document.removeEventListener('mousedown', onPointerDown);
      document.removeEventListener('keydown', onKeyDown);
    };
  }, [open]);

  if (variant === 'inline') {
    return (
      <div className={`lang-inline ${className}`} role="group" aria-label={t('lang.label')}>
        {LOCALES.map((code) => (
          <button
            key={code}
            type="button"
            lang={code}
            className={code === locale ? 'active' : ''}
            aria-pressed={code === locale}
            onClick={() => setLocale(code as Locale)}
          >
            {LOCALE_NAMES[code]}
          </button>
        ))}
      </div>
    );
  }

  return (
    <div className={`lang-menu ${className}`} ref={root}>
      <button
        type="button"
        className="lang-trigger"
        aria-haspopup="listbox"
        aria-expanded={open}
        aria-label={t('lang.label')}
        onClick={() => setOpen((was) => !was)}
      >
        <Icon name="globe" size={15} />
        <span lang={locale}>{LOCALE_NAMES[locale]}</span>
      </button>

      {open && (
        <ul className="lang-list" role="listbox" aria-label={t('lang.label')}>
          {LOCALES.map((code) => (
            <li key={code}>
              <button
                type="button"
                lang={code}
                role="option"
                aria-selected={code === locale}
                className={code === locale ? 'active' : ''}
                onClick={() => {
                  setLocale(code as Locale);
                  setOpen(false);
                }}
              >
                {LOCALE_NAMES[code]}
                {code === locale && <Icon name="check" size={14} />}
              </button>
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}
