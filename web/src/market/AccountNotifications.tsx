// Which optional messages a customer accepts (E6-T10 / F0.10).
//
// Only two switches, and that is the point. Booking confirmations and one-time
// codes are not offered here because they cannot be declined: somebody who
// turned off "your booking is confirmed" would be left with no record of their
// own booking, and the resulting phone call is the thing this whole epic exists
// to prevent. The copy says so plainly rather than leaving the absence to be
// noticed.
import { useState } from 'react';
import { useTranslation } from 'react-i18next';
import { gql } from '../lib/gql';
import { useAuth } from '../lib/auth';
import { useToast } from '../components/ui';

const UPDATE = `mutation($reminders: Boolean, $marketing: Boolean) {
  updateNotificationPrefs(reminders: $reminders, marketing: $marketing) {
    id notificationPrefs { reminders marketing }
  }
}`;

export default function AccountNotifications() {
  const { t } = useTranslation();
  const { user, refreshMe } = useAuth();
  const toast = useToast();
  const [busy, setBusy] = useState(false);

  const prefs = user?.notificationPrefs ?? { reminders: true, marketing: false };

  const set = (key: 'reminders' | 'marketing') => async (value: boolean) => {
    if (busy) return;
    setBusy(true);
    try {
      await gql(UPDATE, { [key]: value });
      await refreshMe();
      toast(t('account.prefsSaved'));
    } catch (e) {
      toast((e as Error).message, true);
    } finally {
      setBusy(false);
    }
  };

  if (!user) return null;

  return (
    <>
      <h2 className="section-title">{t(`account.notificationsTitle`)}</h2>

      <div className="card pad acct-prefs">
        <Toggle
          label={t(`account.remindersLabel`)}
          hint={t(`account.remindersHint`)}
          checked={prefs.reminders !== false}
          busy={busy}
          onChange={set('reminders')}
        />

        <Toggle
          label={t(`account.marketingLabel`)}
          hint={t(`account.marketingHint`)}
          checked={prefs.marketing === true}
          busy={busy}
          onChange={set('marketing')}
        />

        <p className="fainttext acct-prefs-note">{t(`account.notificationsBody`)}</p>
      </div>
    </>
  );
}

function Toggle({
  label,
  hint,
  checked,
  busy,
  onChange,
}: {
  label: string;
  hint: string;
  checked: boolean;
  busy: boolean;
  onChange: (value: boolean) => void;
}) {
  return (
    <label className="acct-toggle">
      <input
        type="checkbox"
        checked={checked}
        disabled={busy}
        onChange={(e) => onChange(e.target.checked)}
      />
      <span>
        <b>{label}</b>
        <span className="fainttext">{hint}</span>
      </span>
    </label>
  );
}
