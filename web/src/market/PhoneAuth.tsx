// Phone sign-in: number → code → (if new) name (E3-T7 / F0.2).
//
// Three screens rather than one form, because each step depends on the last and
// showing them together invites typing a code before one has been sent. The
// step lives in component state, not the URL — a half-finished verification is
// not something to link to or come back to.
import { useEffect, useRef, useState } from 'react';
import { GqlError } from '../lib/gql';
import { useAuth } from '../lib/auth';

type Step = 'phone' | 'code' | 'name';

export default function PhoneAuth({
  onDone,
  initialStep = 'phone',
}: {
  onDone: () => void;
  /**
   * Where to start.
   *
   * `name` is for someone already signed in whose account has never been named
   * — they have a phone and a session, so asking for the number again would be
   * a step backwards.
   */
  initialStep?: Step;
}) {
  const { requestOtp, verifyOtp, completeProfile } = useAuth();

  const [step, setStep] = useState<Step>(initialStep);
  const [phone, setPhone] = useState('');
  const [masked, setMasked] = useState('');
  const [code, setCode] = useState('');
  const [firstName, setFirstName] = useState('');
  const [lastName, setLastName] = useState('');
  const [error, setError] = useState('');
  const [busy, setBusy] = useState(false);
  const [resendIn, setResendIn] = useState(0);

  const codeInput = useRef<HTMLInputElement>(null);

  // The resend countdown mirrors the server's cooldown, so the button is only
  // offered when pressing it would actually work.
  useEffect(() => {
    if (resendIn <= 0) return;
    const timer = setTimeout(() => setResendIn((n) => n - 1), 1000);
    return () => clearTimeout(timer);
  }, [resendIn]);

  useEffect(() => {
    if (step === 'code') codeInput.current?.focus();
  }, [step]);

  const attempt = async (work: () => Promise<void>) => {
    if (busy) return;
    setBusy(true);
    setError('');
    try {
      await work();
    } catch (e) {
      setError(e instanceof GqlError ? e.message : (e as Error).message);
    } finally {
      setBusy(false);
    }
  };

  const send = () =>
    attempt(async () => {
      const request = await requestOtp(phone);
      setMasked(request.maskedPhone);
      setResendIn(request.resendAfter);
      setStep('code');
    });

  const check = () =>
    attempt(async () => {
      const user = await verifyOtp(phone, code);
      // A number nobody has used before has just become an account — ask who
      // they are before handing them the app.
      if (user.profileComplete) onDone();
      else setStep('name');
    });

  const save = () =>
    attempt(async () => {
      await completeProfile(firstName.trim(), lastName.trim() || undefined);
      onDone();
    });

  const onKey = (run: () => void) => (e: React.KeyboardEvent) => {
    if (e.key === 'Enter') run();
  };

  if (step === 'phone') {
    return (
      <div className="auth-fields">
        <div className="auth-field">
          <label htmlFor="otp-phone">Phone number</label>
          <input
            id="otp-phone"
            type="tel"
            inputMode="tel"
            autoComplete="tel"
            placeholder="06 12 34 56 78"
            value={phone}
            onChange={(e) => setPhone(e.target.value)}
            onKeyDown={onKey(send)}
          />
        </div>

        <p className="auth-hint">
          We will text you a 6-digit code. No password needed.
        </p>

        <div className="auth-err">{error}</div>

        <button className="auth-submit" disabled={busy || !phone.trim()} onClick={send}>
          {busy ? 'Sending…' : 'Send code'}
        </button>
      </div>
    );
  }

  if (step === 'code') {
    return (
      <div className="auth-fields">
        <div className="auth-field">
          <label htmlFor="otp-code">Enter the code</label>
          <input
            id="otp-code"
            ref={codeInput}
            type="text"
            inputMode="numeric"
            // Lets iOS and Android offer the code straight from the SMS.
            autoComplete="one-time-code"
            maxLength={6}
            placeholder="123456"
            className="auth-code-input"
            value={code}
            onChange={(e) => setCode(e.target.value.replace(/\D/g, ''))}
            onKeyDown={onKey(check)}
          />
        </div>

        <p className="auth-hint">Sent to {masked}.</p>

        <div className="auth-err">{error}</div>

        <button className="auth-submit" disabled={busy || code.length < 6} onClick={check}>
          {busy ? 'Checking…' : 'Continue'}
        </button>

        <div className="auth-code-actions">
          <button className="linky" disabled={busy || resendIn > 0} onClick={send}>
            {resendIn > 0 ? `Resend in ${resendIn}s` : 'Resend code'}
          </button>
          <button
            className="linky"
            onClick={() => {
              setStep('phone');
              setCode('');
              setError('');
            }}
          >
            Change number
          </button>
        </div>
      </div>
    );
  }

  return (
    <div className="auth-fields">
      <p className="auth-hint">Almost there — what should we call you?</p>

      <div className="auth-row2">
        <div className="auth-field">
          <label htmlFor="otp-first">First name</label>
          <input
            id="otp-first"
            autoComplete="given-name"
            value={firstName}
            onChange={(e) => setFirstName(e.target.value)}
            onKeyDown={onKey(save)}
          />
        </div>
        <div className="auth-field">
          <label htmlFor="otp-last">Last name</label>
          <input
            id="otp-last"
            autoComplete="family-name"
            value={lastName}
            onChange={(e) => setLastName(e.target.value)}
            onKeyDown={onKey(save)}
          />
        </div>
      </div>

      <div className="auth-err">{error}</div>

      <button className="auth-submit" disabled={busy || !firstName.trim()} onClick={save}>
        {busy ? 'Saving…' : 'Finish'}
      </button>
    </div>
  );
}
