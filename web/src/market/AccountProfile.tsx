import { FormEvent, useEffect, useRef, useState } from 'react';
import { useTranslation } from 'react-i18next';
import { gql, GqlError } from '../lib/gql';
import { useAuth } from '../lib/auth';
import type { UploadTicket } from '../lib/types';
import { Icon } from '../lib/icons';
import { useToast } from '../components/ui';

const MAX_AVATAR_BYTES = 10 * 1024 * 1024;

const UPDATE_PROFILE = `mutation($firstName: String!, $lastName: String, $email: String) {
  updateProfile(firstName: $firstName, lastName: $lastName, email: $email) { id }
}`;

const REQUEST_AVATAR = `mutation($contentType: String!, $byteSize: Int) {
  requestAvatarUpload(contentType: $contentType, byteSize: $byteSize) {
    url headers { name value } photo { id }
  }
}`;

export default function AccountProfile() {
  const { t } = useTranslation();
  const { user, refreshMe } = useAuth();
  const toast = useToast();
  const fileInput = useRef<HTMLInputElement>(null);
  const [firstName, setFirstName] = useState('');
  const [lastName, setLastName] = useState('');
  const [email, setEmail] = useState('');
  const [errors, setErrors] = useState<Record<string, string>>({});
  const [saving, setSaving] = useState(false);
  const [avatarBusy, setAvatarBusy] = useState(false);

  useEffect(() => {
    if (!user) return;
    setFirstName(user.firstName ?? '');
    setLastName(user.lastName ?? '');
    setEmail(user.email ?? '');
  }, [user]);

  if (!user) return null;

  const initials = `${user.firstName?.[0] ?? ''}${user.lastName?.[0] ?? ''}`.toUpperCase()
    || user.email?.[0]?.toUpperCase()
    || '?';

  const save = async (event: FormEvent) => {
    event.preventDefault();
    if (saving) return;
    setSaving(true);
    setErrors({});

    try {
      await gql(UPDATE_PROFILE, {
        firstName: firstName.trim(),
        lastName: lastName.trim() || null,
        email: email.trim() || null,
      });
      await refreshMe();
      toast(t('account.profileSaved'));
    } catch (error) {
      if (error instanceof GqlError) setErrors(error.fieldErrors);
      else toast((error as Error).message, true);
    } finally {
      setSaving(false);
    }
  };

  const uploadAvatar = async (file?: File) => {
    if (!file || avatarBusy) return;
    if (file.size > MAX_AVATAR_BYTES) {
      toast(t('account.avatarTooLarge'), true);
      return;
    }

    setAvatarBusy(true);
    try {
      const { requestAvatarUpload: ticket } = await gql<{ requestAvatarUpload: UploadTicket }>(
        REQUEST_AVATAR,
        { contentType: file.type, byteSize: file.size },
      );
      const headers = Object.fromEntries(ticket.headers.map(({ name, value }) => [name, value]));
      const response = await fetch(ticket.url, { method: 'PUT', headers, body: file });
      if (!response.ok) throw new Error(t('account.avatarUploadFailed'));

      await gql(`mutation($id: ID!) { finalizeAvatarUpload(id: $id) { id } }`, {
        id: ticket.photo.id,
      });
      await refreshMe();
      toast(t('account.avatarSaved'));
    } catch (error) {
      toast((error as Error).message, true);
    } finally {
      setAvatarBusy(false);
      if (fileInput.current) fileInput.current.value = '';
    }
  };

  const removeAvatar = async () => {
    if (avatarBusy) return;
    setAvatarBusy(true);
    try {
      await gql(`mutation { deleteAvatar }`);
      await refreshMe();
      toast(t('account.avatarRemoved'));
    } catch (error) {
      toast((error as Error).message, true);
    } finally {
      setAvatarBusy(false);
    }
  };

  return (
    <div className="account-profile">
      <section className="account-avatar-editor" aria-labelledby="avatar-heading">
        <div className="account-avatar account-avatar-lg">
          {user.avatarUrl ? <img src={user.avatarUrl} alt="" /> : <span>{initials}</span>}
        </div>
        <div>
          <h2 id="avatar-heading">{t('account.profilePhoto')}</h2>
          <p className="fainttext">{t('account.avatarHint')}</p>
          <div className="account-avatar-actions">
            <input
              ref={fileInput}
              className="sr-only"
              type="file"
              accept="image/jpeg,image/png,image/webp"
              onChange={(event) => void uploadAvatar(event.target.files?.[0])}
            />
            <button
              type="button"
              className="btn btn-sm"
              disabled={avatarBusy}
              onClick={() => fileInput.current?.click()}
            >
              <Icon name="camera" size={16} />
              {avatarBusy ? t('common.pleaseWait') : t('account.changePhoto')}
            </button>
            {user.avatarUrl && (
              <button type="button" className="btn btn-ghost btn-sm" disabled={avatarBusy} onClick={removeAvatar}>
                {t('common.remove')}
              </button>
            )}
          </div>
        </div>
      </section>

      <form className="account-profile-form" onSubmit={save}>
        <div className="account-profile-grid">
          <Field label={t('account.firstName')} error={errors.firstName}>
            <input value={firstName} onChange={(event) => setFirstName(event.target.value)} required />
          </Field>
          <Field label={t('account.lastName')} error={errors.lastName}>
            <input value={lastName} onChange={(event) => setLastName(event.target.value)} />
          </Field>
          <Field label={t('common.email')} error={errors.email} wide>
            <input type="email" autoComplete="email" value={email} onChange={(event) => setEmail(event.target.value)} />
          </Field>
          <Field label={t('common.phone')} wide hint={t('account.phoneVerifiedHint')}>
            <input value={user.phone || t('account.noPhone')} disabled />
          </Field>
        </div>
        <button className="btn btn-primary" disabled={saving || !firstName.trim()}>
          {saving ? t('common.saving') : t('account.saveProfile')}
        </button>
      </form>
    </div>
  );
}

function Field({
  label,
  error,
  hint,
  wide = false,
  children,
}: {
  label: string;
  error?: string;
  hint?: string;
  wide?: boolean;
  children: React.ReactNode;
}) {
  return (
    <label className={`account-field${wide ? ' account-field-wide' : ''}`}>
      <span>{label}</span>
      {children}
      {error && <small className="account-field-error">{error}</small>}
      {!error && hint && <small>{hint}</small>}
    </label>
  );
}
