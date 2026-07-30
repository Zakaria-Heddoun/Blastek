// Shared chrome and form plumbing for the two auth pages — the client-side
// AuthPage and the professional-side ProLogin. They differ only in copy, which
// fields show, and what happens after a successful submit.
import { useRef, useState } from 'react';
import type { ReactNode } from 'react';
import { Link } from 'react-router-dom';
import { motion } from 'framer-motion';
import { GqlError } from '../lib/gql';
import { IMG } from './assets';
import '../bungee/bungee.css';
import './home.css';
import './auth.css';

export interface AuthFields {
  email: string;
  password: string;
  firstName: string;
  lastName: string;
  phone: string;
  /** Only used when registering a business — creates the venue. */
  businessName: string;
}

const EMPTY: AuthFields = {
  email: '', password: '', firstName: '', lastName: '', phone: '', businessName: '',
};

// Only same-origin absolute paths survive; `//host`, `/\host` and absolute URLs
// fall back to the homepage.
export function safeNext(raw: string | null): string {
  if (!raw || raw[0] !== '/' || raw[1] === '/' || raw[1] === '\\') return '/';
  return raw;
}

export function useAuthForm(onSubmit: (f: AuthFields) => Promise<void>) {
  const [f, setF] = useState(EMPTY);
  const [err, setErr] = useState('');
  const [fieldErrors, setFieldErrors] = useState<Record<string, string>>({});
  const [busy, setBusy] = useState(false);
  // Enter fires even while the submit button is disabled, and two keydowns can
  // land before a `busy` state update is visible — the ref closes that window.
  const inFlight = useRef(false);

  const set = (k: keyof AuthFields) => (e: React.ChangeEvent<HTMLInputElement>) => {
    setF((prev) => ({ ...prev, [k]: e.target.value }));
    // Editing a field clears the complaint about it.
    setFieldErrors((prev) => (k in prev ? omit(prev, k) : prev));
  };

  const submit = async () => {
    if (inFlight.current) return;
    inFlight.current = true;
    setErr('');
    setFieldErrors({});
    setBusy(true);
    try {
      await onSubmit(f);
    } catch (e) {
      if (e instanceof GqlError) {
        const fields = e.fieldErrors;
        setFieldErrors(fields);
        // Only surface the summary for errors no field claimed, so a message
        // is never shown twice.
        const unclaimed = e.details.filter((d) => !d.field).map((d) => d.message);
        setErr(unclaimed.join('; ') || (Object.keys(fields).length ? '' : e.message));
      } else {
        setErr((e as Error).message);
      }
    } finally {
      inFlight.current = false;
      setBusy(false);
    }
  };

  const onKey = (e: React.KeyboardEvent) => {
    if (e.key === 'Enter') submit();
  };

  return { f, set, err, setErr, fieldErrors, busy, submit, onKey };
}

function omit(obj: Record<string, string>, key: string) {
  const { [key]: _dropped, ...rest } = obj;
  return rest;
}

export type AuthForm = ReturnType<typeof useAuthForm>;

export function AuthField({
  label, name, type, placeholder, form,
}: {
  label: string;
  name: keyof AuthFields;
  type?: string;
  placeholder?: string;
  form: AuthForm;
}) {
  const fieldError = form.fieldErrors[name];

  return (
    <div className={`auth-field${fieldError ? ' has-error' : ''}`}>
      <label>{label}</label>
      <input
        type={type}
        placeholder={placeholder}
        value={form.f[name]}
        onChange={form.set(name)}
        onKeyDown={form.onKey}
        aria-invalid={fieldError ? true : undefined}
      />
      {fieldError && <span className="auth-field-err">{fieldError}</span>}
    </div>
  );
}

export default function AuthShell({
  media, eyebrow, title, sub, form, fields, submitLabel, toggle, onToggle, demo, body, above,
}: {
  media: { eyebrow: string; heading: ReactNode };
  eyebrow: string;
  title: string;
  sub: string;
  form: AuthForm;
  fields: ReactNode;
  submitLabel: string;
  toggle: ReactNode;
  onToggle: () => void;
  demo?: string;
  /**
   * Replaces the fields, error and submit button entirely.
   *
   * A multi-step flow such as phone verification owns its own buttons and error
   * placement; forcing it through the single-submit chrome would mean a "Sign
   * in" button that means something different on each step.
   */
  body?: ReactNode;
  /** Rendered above the form — the sign-in method switcher. */
  above?: ReactNode;
}) {
  return (
    <div className="bungee blastek-home auth-shell">
      <Link to="/" className="auth-back" aria-label="Blastek home">
        <span className="brand-word">blastek</span>
      </Link>

      <div className="auth-grid">
        <div className="auth-media" aria-hidden="true">
          <div className="arch-media">
            <img src={IMG.salon1} alt="" />
            <div className="auth-media-cap">
              <span className="mono">( {media.eyebrow} )</span>
              <h2>{media.heading}</h2>
            </div>
          </div>
        </div>

        <div className="auth-form-col">
          <motion.div
            className="auth-form"
            initial={{ opacity: 0, y: 20 }}
            animate={{ opacity: 1, y: 0 }}
            transition={{ duration: 0.55, ease: [0.2, 0.8, 0.2, 1] }}
          >
            <span className="mono">( {eyebrow} )</span>
            <h1 className="auth-title">{title}</h1>
            <p className="auth-sub">{sub}</p>

            {above}

            {body ?? (
              <>
                <div className="auth-fields">{fields}</div>

                <div className="auth-err">{form.err}</div>

                <button className="auth-submit" disabled={form.busy} onClick={form.submit}>
                  {form.busy ? 'Please wait…' : submitLabel}
                </button>
              </>
            )}

            <button
              className="auth-toggle"
              onClick={() => {
                form.setErr('');
                onToggle();
              }}
            >
              {toggle}
            </button>

            {demo && <div className="auth-demo">Demo — {demo}</div>}
          </motion.div>
        </div>
      </div>
    </div>
  );
}
