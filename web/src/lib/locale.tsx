// Choosing a language, and keeping that choice in the three places it has to
// live (E7-T1 / F0.11).
//
// Those places are `localStorage` (so a reload does not undo it), the i18next
// instance (so the interface re-renders) and the **account** (so a phone and a
// laptop agree, and so WhatsApp reminders arrive in the language the person
// chose — the half a localStorage key can never do).
//
// The account write is deliberately not awaited by the UI: switching language
// must feel instant and must work signed out. A failed save costs the
// cross-device half, not the switch.
import { useCallback, useEffect } from 'react';
import { useTranslation } from 'react-i18next';
import { gql } from './gql';
import { isLocale, type Locale } from './i18n';
import { useAuth } from './auth';

export function useLocale() {
  const { i18n } = useTranslation();
  const { user, refreshMe } = useAuth();

  const locale = (isLocale(i18n.resolvedLanguage) ? i18n.resolvedLanguage : 'fr') as Locale;

  const setLocale = useCallback(
    (next: Locale) => {
      void i18n.changeLanguage(next);

      if (user) {
        gql('mutation($locale: String!) { updateLocale(locale: $locale) { id locale } }', {
          locale: next,
        })
          .then(() => refreshMe())
          .catch(() => {
            // Offline, or a session that just expired. The interface has
            // already switched; only the cross-device half is lost.
          });
      }
    },
    [i18n, user, refreshMe],
  );

  return { locale, setLocale };
}

/**
 * Adopts the language saved on the account, once, when a session appears.
 *
 * Only when the visitor has not already chosen in *this* browser: someone who
 * just switched to Arabic and then signed in should stay in Arabic rather than
 * be yanked back by a preference they set months ago on another device. That is
 * why this reads `localStorage` directly instead of asking i18next, which
 * cannot tell a detected language from a chosen one.
 */
export function useAccountLocale() {
  const { i18n } = useTranslation();
  const { user } = useAuth();
  const saved = user?.locale;

  useEffect(() => {
    if (!saved || !isLocale(saved)) return;
    if (localStorage.getItem('blastek-locale')) return;
    if (i18n.resolvedLanguage === saved) return;

    void i18n.changeLanguage(saved);
  }, [saved, i18n]);
}
