// Interface language: French by default, Arabic RTL, English kept (E7-T1 / F0.11).
//
// ## Why French is the default and English is not the fallback
//
// The market is Morocco. A salon owner types French, a customer reads French or
// Arabic, and English exists for tourists and for us. So `fr` is both the
// default *and* the fallback: a key missing from `ar` shows the French string,
// never the raw key, and never English.
//
// ## Direction is a document property, not a component prop
//
// `dir="rtl"` goes on `<html>`, which is what makes the browser's own bidi
// algorithm, form controls, scrollbars and `text-align: start` all agree. Every
// attempt to do this per-component ends with a dropdown that opens off the left
// edge of the screen.
import i18next from 'i18next';
import { initReactI18next } from 'react-i18next';
import LanguageDetector from 'i18next-browser-languagedetector';

import ar from '../locales/ar.json';
import en from '../locales/en.json';
import fr from '../locales/fr.json';

export const LOCALES = ['fr', 'ar', 'en'] as const;
export type Locale = (typeof LOCALES)[number];

/** Endonyms — a language picker that names languages in a language you may not read is useless. */
export const LOCALE_NAMES: Record<Locale, string> = {
  fr: 'Français',
  ar: 'العربية',
  en: 'English',
};

export const RTL_LOCALES: Locale[] = ['ar'];

export const STORAGE_KEY = 'blastek-locale';

export const isLocale = (value: unknown): value is Locale =>
  typeof value === 'string' && (LOCALES as readonly string[]).includes(value);

export const isRtl = (locale: string) => RTL_LOCALES.includes(locale as Locale);

/**
 * Applies a locale to the document.
 *
 * `lang` matters as much as `dir`: it is what tells the browser which font to
 * reach for, how to hyphenate, and what to read aloud. A page of Arabic marked
 * `lang="fr"` renders in whatever the French font stack has for Arabic, which
 * is rarely what anybody wants.
 */
export function applyDocumentLocale(locale: string) {
  const root = document.documentElement;
  root.lang = locale;
  root.dir = isRtl(locale) ? 'rtl' : 'ltr';
  // Lets CSS target the direction without duplicating the check, and survives
  // `dir` being overridden on a subtree for a mixed-direction string.
  root.dataset.locale = locale;
}

void i18next
  .use(LanguageDetector)
  .use(initReactI18next)
  .init({
    resources: {
      fr: { translation: fr },
      ar: { translation: ar },
      en: { translation: en },
    },
    fallbackLng: 'fr',
    supportedLngs: LOCALES as unknown as string[],
    // `fr-FR` and `fr-CA` are both French here. Without this a browser sending
    // a region tag matches no bundle and silently falls back.
    load: 'languageOnly',
    nonExplicitSupportedLngs: true,
    detection: {
      // The saved choice first: somebody who picked Arabic meant it more than
      // their phone's system locale did, and phones sold in Morocco very often
      // ship set to French or English whatever their owner reads.
      order: ['localStorage', 'navigator'],
      lookupLocalStorage: STORAGE_KEY,
      caches: ['localStorage'],
    },
    interpolation: {
      // React escapes for us; doing it twice turns an apostrophe in "l'équipe"
      // into `&#39;` on screen.
      escapeValue: false,
    },
    returnNull: false,
  });

applyDocumentLocale(i18next.resolvedLanguage ?? 'fr');

i18next.on('languageChanged', (locale) => applyDocumentLocale(locale));

export default i18next;
