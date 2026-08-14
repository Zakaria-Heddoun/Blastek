// Fails the build on a hardcoded user-facing string, and on a translation file
// that has drifted out of step with French (E7-T8 / F0.11).
//
// ## Why a bespoke script rather than an eslint plugin
//
// `eslint-plugin-i18next` finds JSX text, which is roughly half the problem.
// The other half is the attributes nobody remembers — `placeholder`,
// `aria-label`, `title`, `alt` — and those are exactly the strings that stay
// English for a year because no one *sees* them until a screen reader does.
// This checks both, and it also checks the thing an extraction linter cannot:
// that `ar.json` still has every key `fr.json` does.
//
// The rule is deliberately narrow. It flags text that looks like a *sentence a
// person reads* — starts with a capital letter or contains a space — and
// ignores the rest, because a CSS class, a GraphQL field and a date format
// string are all "strings in the source" and none of them are copy. A gate that
// cries wolf is a gate somebody adds `// eslint-disable` above.
import { readFileSync, readdirSync, statSync } from 'node:fs';
import { join, relative } from 'node:path';

const SRC = new URL('../src', import.meta.url).pathname.replace(/^\/([A-Za-z]:)/, '$1');
const LOCALES = join(SRC, 'locales');

const problems = [];

// Files that legitimately hold no user-facing copy, or hold it by design.
const SKIP_FILES = [
  /[\\/]locales[\\/]/,
  /[\\/]lib[\\/]i18n\.ts$/,
  // A standalone re-creation of a marketing template, not part of the product
  // (see the route comment in App.tsx). Localizing it would mean translating
  // somebody else's copy.
  /[\\/]bungee[\\/]/,
  /\.test\.tsx?$/,
  /vite-env\.d\.ts$/,
];

// Attributes a person reads. `alt` and `aria-label` are here because they are
// the ones that never get noticed.
const TEXT_ATTRS = ['placeholder', 'aria-label', 'ariaLabel', 'title', 'alt', 'aria-description'];

function* walk(dir) {
  for (const entry of readdirSync(dir)) {
    const full = join(dir, entry);
    if (statSync(full).isDirectory()) yield* walk(full);
    else if (/\.tsx?$/.test(full)) yield full;
  }
}

/** Copy, as opposed to an identifier, a class list or a format string. */
function looksLikeCopy(text) {
  const trimmed = text.trim();
  // Three, not four: "Map" is a button label and was slipping past a longer floor.
  if (trimmed.length < 3) return false;
  // No letters at all: separators, arrows, punctuation.
  if (!/\p{L}/u.test(trimmed)) return false;
  // A single lowercase token is an identifier, a slug, a class or a key.
  if (!/\s/.test(trimmed) && !/^[A-Z]/.test(trimmed)) return false;
  // Class lists and utility strings: several lowercase words, no sentence case.
  if (/^[a-z0-9-]+( [a-z0-9-]+)*$/.test(trimmed)) return false;
  // Anything already interpolated or templated is checked by eye, not here.
  if (/^https?:|^\/|^[#.]/.test(trimmed)) return false;
  // Code that happened to sit between the `>` of one generic and the `<` of the
  // next — `useState<Foo>([]); const [b, setB] = useState<Bar>`. Scanning whole
  // files rather than single lines is what makes wrapped JSX visible, and this
  // is the price: the span between two brackets is not always a text node.
  // Copy contains none of these.
  if (/&&|\|\||=>|\?\.|\{|\}|;|=|\bconst\b|\buse[A-Z]\w+\(/.test(trimmed)) return false;
  // A JSX comment, or a ternary whose arms happen to bracket the span.
  if (trimmed.includes('//') || /^\)|\($/.test(trimmed)) return false;
  // A CSS value, not a sentence.
  if (/^(linear-gradient|radial-gradient|rgba?|hsla?|url|calc|var|translate|matrix)\(/.test(trimmed)) {
    return false;
  }
  // SVG path data — a command letter, then numbers. Ruled out by shape rather
  // than by skipping `icons.tsx` wholesale, because that file also holds a real
  // `aria-label`, and a whole-file exemption hid it.
  if (/^[MmLlHhVvCcSsQqTtAaZz][\s\d.,-]/.test(trimmed) && !/[a-z]{3}/i.test(trimmed.replace(/[MmLlHhVvCcSsQqTtAaZz]/g, ''))) {
    return false;
  }
  return true;
}

function checkSource(file) {
  const rel = relative(SRC, file).replace(/\\/g, '/');
  if (SKIP_FILES.some((re) => re.test(file))) return;

  const source = readFileSync(file, 'utf8');
  const lines = source.split('\n');
  const lineAt = (index) => source.slice(0, index).split('\n').length;

  // An exemption applies to its own line and the one after it, because JSX has
  // nowhere to put a trailing comment inside an attribute list.
  const exempt = (line) =>
    /i18n-exempt/.test(lines[line - 1] ?? '') || /i18n-exempt/.test(lines[line - 2] ?? '');
  const inComment = (line) => /^\s*(\/\/|\*|\/\*)/.test(lines[line - 1] ?? '');

  const report = (index, kind, value) => {
    const line = lineAt(index);
    if (exempt(line) || inComment(line)) return;
    problems.push(`${rel}:${line}  hardcoded ${kind}: ${JSON.stringify(value.trim())}`);
  };

  // 1. JSX text between tags — matched across the *whole file*, not line by
  //    line, because Prettier wraps long elements and the text then sits on its
  //    own line with neither bracket on it:
  //
  //        <div className="empty">
  //          No venues match that search.
  //        </div>
  //
  //    A line-scoped regex sees nothing there, which is the most dangerous way
  //    for this gate to be wrong: it reports success over untranslated copy.
  //
  //    Only in `.tsx`, because a `.ts` file has no JSX and every `<…>` in one is
  //    a generic. The lookbehind excludes `=>`, without which
  //    `() => Promise<void>` reads as the JSX text "Promise".
  if (file.endsWith('.tsx')) {
    for (const match of source.matchAll(/(?<![=|&])>([^<>{}]+)</g)) {
      // Collapse the wrapping so "No venues\n  match" reads as one sentence.
      const text = match[1].replace(/\s+/g, ' ');
      if (looksLikeCopy(text)) report(match.index, 'JSX text', text);
    }
  }

  // 2. Literal text in an attribute a person reads. `ariaLabel` is the
  //    camelCase prop our own components take, as opposed to the DOM's
  //    `aria-label`; both are the same string to the same screen reader.
  //
  //    The last alternative covers `aria-label={`${day} opens`}`. A template
  //    literal is the one attribute form that reads as code, so it is the one
  //    that keeps its English longest — and these are screen-reader-only
  //    strings, which nobody *sees* go wrong.
  for (const attr of TEXT_ATTRS) {
    const re = new RegExp(
      `\\b${attr}\\s*=\\s*(?:"([^"]+)"|'([^']+)'|\\{\\s*['"\`]([^'"\`]+)['"\`]\\s*\\}|\\{\`([^\`]+)\`\\})`,
      'g',
    );
    for (const match of source.matchAll(re)) {
      const value = match[1] ?? match[2] ?? match[3] ?? match[4];
      // Strip the interpolations; what is left is the copy around them.
      const words = value.replace(/\$\{[^}]*\}/g, ' ').trim();

      // These attributes are copy *by construction* — an `aria-label` is never
      // an identifier or a class list — so the bar is lower than for a bare
      // string literal: any three letters make it a phrase somebody reads.
      // Without this, `aria-label={`${day} opens`}` passes as "opens", which
      // the general rule discards as a lowercase token.
      if (/\p{L}{3}/u.test(words) && !/^\s*$/.test(words)) report(match.index, attr, value);
    }
  }

  // 3. Copy hiding in object literals — `{ value: 'rating', label: 'Top rated' }`
  //    is a dropdown option, and no amount of JSX scanning will find it.
  for (const match of source.matchAll(/\b(label|title|desc|placeholder|hint)\s*:\s*'([^']{4,})'/g)) {
    if (looksLikeCopy(match[2])) report(match.index, `${match[1]} property`, match[2]);
  }

  // 4. Sentences thrown as errors or handed to a toast — user-facing too.
  for (const match of source.matchAll(/(?:toast|Error)\(\s*(['"])([^'"]{8,})\1/g)) {
    if (looksLikeCopy(match[2])) report(match.index, 'message', match[2]);
  }

  // 5. Any remaining multi-word literal — `{searched ? 'Search results' : 'Book
  //    an appointment'}` is a heading that neither the JSX-text scan nor the
  //    attribute scan can see, because it lives inside an expression.
  //
  //    Restricted to strings containing a space, which is what keeps
  //    `'Africa/Casablanca'`, `'2-digit'` and every CSS value out of the
  //    results. Single-word copy escapes this rule; the JSX scan catches most
  //    of it, and a gate that flags `'numeric'` is a gate people switch off.
  //    The regex matches *every* string literal rather than only the ones with
  //    a space in them, and filters afterwards. Filtering inside the pattern
  //    makes the scanner skip a string and then start matching at its closing
  //    quote, so `{ to: '/x', key: 'y' }` reports the `, key: ` between them.
  for (const match of source.matchAll(/'([^'\\\n]*(?:\\.[^'\\\n]*)*)'|"([^"\\\n]*(?:\\.[^"\\\n]*)*)"/g)) {
    const value = match[1] ?? match[2] ?? '';
    if (!/\s/.test(value)) continue;
    const before = source.slice(Math.max(0, match.index - 24), match.index);

    // Already translated, an import path, or a key.
    if (/\bt\(\s*$|i18nKey=\s*$|defaultValue:\s*$|from\s+$|import\s+$/.test(before)) continue;
    // A GraphQL document, a class list, a style value, a selector.
    if (/className=\s*$|style=\s*$|querySelector\w*\(\s*$|\.\w+\(\s*$/.test(before)) continue;
    if (!looksLikeCopy(value)) continue;

    report(match.index, 'string literal', value);
  }
}

/** Every leaf key, dotted. */
function keysOf(object, prefix = '') {
  return Object.entries(object).flatMap(([key, value]) =>
    // An array is a leaf: `t('home.faq', { returnObjects: true })` asks for the
    // whole list, so `home.faq.0` is not a key anybody references.
    value && typeof value === 'object' && !Array.isArray(value)
      ? keysOf(value, `${prefix}${key}.`)
      : [`${prefix}${key}`],
  );
}

/**
 * Every key the source asks for exists in French.
 *
 * The parity check below compares the bundles to each other, which says nothing
 * about whether either has what the app calls for — delete a key still in use
 * and all three files agree perfectly while the page renders the literal string
 * `venues.useMyLocation` to a customer. Only looking at the screen catches that,
 * and only until nobody looks.
 */
function checkReferences() {
  const fr = JSON.parse(readFileSync(join(LOCALES, 'fr.json'), 'utf8'));
  const known = new Set(keysOf(fr));

  for (const file of walk(SRC)) {
    if (/[\\/]locales[\\/]/.test(file)) continue;
    const source = readFileSync(file, 'utf8');
    const rel = relative(SRC, file).replace(/\\/g, '/');

    for (const match of source.matchAll(/\bt\(\s*['"`]([a-zA-Z][\w.]*)['"`]/g)) {
      const key = match[1];
      // Plural and interpolated forms resolve from the base key.
      const has =
        known.has(key) || [...known].some((k) => k.replace(/_(zero|one|two|few|many|other)$/, '') === key);
      if (!has) {
        const line = source.slice(0, match.index).split('\n').length;
        problems.push(`${rel}:${line}  key not in fr.json: ${key}`);
      }
    }
  }
}

function checkLocales() {
  const load = (name) => JSON.parse(readFileSync(join(LOCALES, `${name}.json`), 'utf8'));
  const fr = keysOf(load('fr'));

  for (const locale of ['ar', 'en']) {
    const theirs = new Set(keysOf(load(locale)));

    // i18next resolves `key_one`/`key_other` from a plural rule that differs
    // per language — Arabic has six forms, French two — so a missing plural
    // variant is not drift. Compare on the base key.
    const base = (key) => key.replace(/_(zero|one|two|few|many|other)$/, '');
    const theirBases = new Set([...theirs].map(base));

    for (const key of fr) {
      if (!theirs.has(key) && !theirBases.has(base(key))) {
        problems.push(`locales/${locale}.json  missing key: ${key}`);
      }
    }
  }
}

for (const file of walk(SRC)) checkSource(file);
checkReferences();
checkLocales();

if (problems.length) {
  console.error(`\n${problems.length} i18n problem(s):\n`);
  for (const problem of problems) console.error('  ' + problem);
  console.error(
    '\nUse t(\'key\') for anything a person reads. If a string genuinely is not copy,\n' +
      'add a trailing `i18n-exempt` comment saying why.\n',
  );
  process.exit(1);
}

console.log('i18n: no hardcoded copy, and every locale has every key.');
