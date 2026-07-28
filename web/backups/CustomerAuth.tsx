// Customer sign-in / sign-up — required to book, like Fresha.
import { useState } from 'react';
import { useNavigate, useSearchParams } from 'react-router-dom';
import { useAuth } from '../lib/auth';
import { Sparkle } from '../lib/icons';

export default function CustomerAuth() {
  const { login, signUp } = useAuth();
  const navigate = useNavigate();
  const [params] = useSearchParams();
  const next = params.get('next') || '/';
  const [mode, setMode] = useState<'login' | 'signup'>(params.has('signup') ? 'signup' : 'login');
  const [f, setF] = useState({ email: '', password: '', firstName: '', lastName: '', phone: '' });
  const [err, setErr] = useState('');
  const [busy, setBusy] = useState(false);

  const submit = async () => {
    setErr('');
    setBusy(true);
    try {
      if (mode === 'login') await login(f.email, f.password);
      else await signUp({ ...f, role: 'customer' });
      navigate(next);
    } catch (e) {
      setErr((e as Error).message);
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="auth-page sparkle-field">
      <div className="card auth-card">
        <div className="logo" style={{ padding: 0, justifyContent: 'center' }}>
          <span className="spark"><Sparkle size={20} /></span>blastek
        </div>
        <h1 style={{ fontSize: 22, textAlign: 'center', margin: '14px 0 4px' }}>
          {mode === 'login' ? 'Welcome back' : 'Create your account'}
        </h1>
        <p className="mutetext" style={{ textAlign: 'center', marginTop: 0 }}>
          {mode === 'login' ? 'Sign in to book and manage your appointments.'
            : 'One account for all your bookings.'}
        </p>
        {mode === 'signup' && (
          <>
            <div className="grid2">
              <div><label>First name *</label>
                <input value={f.firstName} onChange={(e) => setF({ ...f, firstName: e.target.value })} /></div>
              <div><label>Last name</label>
                <input value={f.lastName} onChange={(e) => setF({ ...f, lastName: e.target.value })} /></div>
            </div>
            <label>Phone</label>
            <input placeholder="+212 6 …" value={f.phone} onChange={(e) => setF({ ...f, phone: e.target.value })} />
          </>
        )}
        <label>Email</label>
        <input type="email" value={f.email} onChange={(e) => setF({ ...f, email: e.target.value })}
          onKeyDown={(e) => e.key === 'Enter' && submit()} />
        <label>Password{mode === 'signup' ? ' (min 8 characters)' : ''}</label>
        <input type="password" value={f.password} onChange={(e) => setF({ ...f, password: e.target.value })}
          onKeyDown={(e) => e.key === 'Enter' && submit()} />
        <div className="err">{err}</div>
        <button className="btn btn-accent" style={{ width: '100%', justifyContent: 'center', padding: 11, borderRadius: 999 }}
          disabled={busy} onClick={submit}>
          {mode === 'login' ? 'Sign in' : 'Create account'}
        </button>
        <button className="btn btn-ghost btn-sm" style={{ width: '100%', justifyContent: 'center', marginTop: 10 }}
          onClick={() => { setMode(mode === 'login' ? 'signup' : 'login'); setErr(''); }}>
          {mode === 'login' ? "Don't have an account? Sign up" : 'Already have an account? Sign in'}
        </button>
        <div className="fainttext" style={{ textAlign: 'center', marginTop: 14 }}>
          Demo: leila.bennani@example.com · blastek123
        </div>
      </div>
    </div>
  );
}
