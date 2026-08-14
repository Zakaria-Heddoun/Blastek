// Who can sign in to this venue, and at what level (E4-T4 / F0.3).
//
// Deliberately separate from the staff roster next to it: a `staff` row is a
// calendar column that takes appointments, a membership is a login. Most people
// are both, some are only one — a silent partner who sees the books but never
// holds scissors, a junior who is booked but has no dashboard account — and
// merging the two concepts is what makes "remove their access" accidentally
// delete a year of appointments.
import { useCallback, useEffect, useState } from 'react';
import { useTranslation } from 'react-i18next';
import { gql } from '../lib/gql';
import type { Staff } from '../lib/types';
import { Modal, useToast } from '../components/ui';
import { Icon } from '../lib/icons';
import { useAuth } from '../lib/auth';

interface Member {
  id: string;
  role: string;
  staffId: string | null;
  user: { id: string; firstName: string; lastName: string; email: string | null; phone: string };
}

interface Invitation {
  id: string;
  role: string;
  phone: string;
  email: string;
  expiresAt: string;
}

const LOAD = `{
  venueMembers { id role staffId user { id firstName lastName email phone } }
  pendingInvitations { id role phone email expiresAt }
}`;

const ROLES = [
  { value: 'owner', labelKey: 'admin.team.roles.owner', hintKey: 'admin.team.ownerHint' },
  { value: 'manager', labelKey: 'admin.team.roles.manager', hintKey: 'admin.team.managerHint' },
  { value: 'receptionist', labelKey: 'admin.team.roles.receptionist', hintKey: 'admin.team.receptionistHint' },
  { value: 'staff', labelKey: 'admin.team.roles.staff', hintKey: 'admin.team.staffHint' },
];

// Roles are stored in English; what a member is *called* is copy.
const roleLabelKey = (value: string) =>
  ROLES.find((r) => r.value === value)?.labelKey ?? `admin.team.roles.${value}`;

export default function MembersTab({ staff }: { staff: Staff[] }) {
  const { t } = useTranslation();
  const { user } = useAuth();
  const toast = useToast();

  const [members, setMembers] = useState<Member[] | null>(null);
  const [invitations, setInvitations] = useState<Invitation[]>([]);
  const [inviting, setInviting] = useState(false);
  const [busy, setBusy] = useState(false);

  const load = useCallback(async () => {
    try {
      const d = await gql<{ venueMembers: Member[]; pendingInvitations: Invitation[] }>(LOAD);
      setMembers(d.venueMembers ?? []);
      setInvitations(d.pendingInvitations ?? []);
    } catch (e) {
      toast((e as Error).message, true);
      setMembers([]);
    }
  }, [toast]);

  useEffect(() => {
    load();
  }, [load]);

  const act = async (query: string, variables: Record<string, unknown>, done: string) => {
    if (busy) return;
    setBusy(true);
    try {
      await gql(query, variables);
      toast(done);
      await load();
    } catch (e) {
      toast((e as Error).message, true);
    } finally {
      setBusy(false);
    }
  };

  const owners = (members ?? []).filter((m) => m.role === 'owner').length;

  return (
    <>
      <div className="page-head">
        <div>
          <h2 style={{ fontSize: 16, margin: 0 }}>{t(`admin.team.access`)}</h2>
          <p className="mutetext" style={{ margin: '4px 0 0', fontSize: 13 }}>
            {t(`admin.team.accessBody`)}
          </p>
        </div>
        <div className="grow" />
        <button className="btn btn-primary" onClick={() => setInviting(true)}>
          <Icon name="plus" size={16} /> {t(`admin.team.invite`)}
        </button>
      </div>

      {members === null && <div className="empty">{t(`common.loading`)}</div>}

      <div className="member-rows">
        {members?.map((member) => {
          const isMe = member.user?.id === user?.id;
          // The server refuses this too; hiding it avoids offering an action
          // that can only fail.
          const lastOwner = member.role === 'owner' && owners <= 1;

          return (
            <div key={member.id} className="card pad member-row">
              <div className="grow">
                <b>
                  {[member.user?.firstName, member.user?.lastName].filter(Boolean).join(' ') ||
                    member.user?.phone ||
                    t('admin.team.invited')}
                </b>
                {isMe && <span className="member-you">{t(`common.you`)}</span>}
                <div className="fainttext">
                  {member.user?.email || member.user?.phone || '—'}
                  {member.staffId && ` ${t('admin.team.hasCalendar')}`}
                </div>
              </div>

              <select
                aria-label={`Role for ${member.user?.firstName ?? 'member'}`}
                value={member.role}
                disabled={busy || lastOwner}
                onChange={(e) =>
                  act(
                    `mutation($id: ID!, $role: String!) {
                      updateMemberRole(id: $id, role: $role) { id role } }`,
                    { id: member.id, role: e.target.value },
                    t('admin.team.roleUpdated'),
                  )
                }
              >
                {ROLES.map((r) => (
                  <option key={r.value} value={r.value}>{t(r.labelKey)}</option>
                ))}
              </select>

              <button
                className="btn btn-sm btn-danger"
                disabled={busy || lastOwner}
                title={lastOwner ? t('admin.team.lastOwner') : undefined}
                onClick={() =>
                  act(
                    `mutation($id: ID!) { removeMember(id: $id) { id } }`,
                    { id: member.id },
                    t('admin.team.accessRemoved'),
                  )
                }
              >
                {t(`common.remove`)}
              </button>
            </div>
          );
        })}
      </div>

      {invitations.length > 0 && (
        <>
          <h2 className="section-title" style={{ fontSize: 15 }}>{t(`admin.team.pendingInvitations`)}</h2>
          <div className="member-rows">
            {invitations.map((invitation) => (
              <div key={invitation.id} className="card pad member-row is-pending">
                <div className="grow">
                  <b>{invitation.phone || invitation.email}</b>
                  <div className="fainttext">
                    {t(`admin.team.invitedAs`, {
                      role: t(roleLabelKey(invitation.role)),
                      date: new Date(`${invitation.expiresAt}Z`).toLocaleDateString(),
                    })}
                  </div>
                </div>
                <button
                  className="btn btn-sm"
                  disabled={busy}
                  onClick={() =>
                    act(
                      `mutation($id: ID!) { revokeInvitation(id: $id) { id } }`,
                      { id: invitation.id },
                      t('admin.team.invitationWithdrawn'),
                    )
                  }
                >
                  {t(`admin.team.withdraw`)}
                </button>
              </div>
            ))}
          </div>
        </>
      )}

      {inviting && (
        <InviteModal
          staff={staff}
          onClose={() => setInviting(false)}
          onDone={() => {
            setInviting(false);
            load();
          }}
        />
      )}
    </>
  );
}

function InviteModal({
  staff,
  onClose,
  onDone,
}: {
  staff: Staff[];
  onClose: () => void;
  onDone: () => void;
}) {
  const { t } = useTranslation();
  const toast = useToast();
  const [role, setRole] = useState('staff');
  const [phone, setPhone] = useState('');
  const [staffId, setStaffId] = useState('');
  const [busy, setBusy] = useState(false);
  const [link, setLink] = useState('');
  const [delivered, setDelivered] = useState(true);

  const send = async () => {
    if (busy) return;
    setBusy(true);
    try {
      const d = await gql<{ inviteMember: { url: string; delivered: boolean } }>(
        `mutation($role: String!, $phone: String, $staffId: ID) {
          inviteMember(role: $role, phone: $phone, staffId: $staffId) { url delivered } }`,
        { role, phone, staffId: staffId || null },
      );
      // Shown as well as sent: the link is unrecoverable afterwards, and an
      // owner standing next to the invitee should not have to wait for an SMS.
      setLink(d.inviteMember.url);
      setDelivered(d.inviteMember.delivered);
      toast(d.inviteMember.delivered ? t('admin.team.invitationSent') : t('admin.team.invitationCreated'));
    } catch (e) {
      toast((e as Error).message, true);
    } finally {
      setBusy(false);
    }
  };

  return (
    <Modal onClose={link ? onDone : onClose}>
      <h2 style={{ fontSize: 17, margin: '0 0 14px' }}>{t(`admin.team.inviteMember`)}</h2>
      {link ? (
        <div className="invite-done">
          <p className="mutetext">
            {/* Never claim "sent" when the message did not go out — that leaves
                an owner waiting for something that is not coming. */}
            {delivered
              ? `Sent to ${phone}. You can also share this link directly`
              : `We could not text ${phone}, so share this link instead`}{' '}
            — it works once and expires in 7 days.
          </p>
          <input readOnly value={link} onFocus={(e) => e.currentTarget.select()} />
          <button className="btn btn-primary" onClick={onDone}>{t(`admin.team.done`)}</button>
        </div>
      ) : (
        <div className="invite-form">
          <label>
            {t(`admin.team.mobileNumber`)}
            <input
              type="tel"
              inputMode="tel"
              placeholder="06 12 34 56 78"
              value={phone}
              onChange={(e) => setPhone(e.target.value)}
            />
          </label>

          <fieldset className="invite-roles">
            <legend>{t(`admin.team.role`)}</legend>
            {ROLES.map((r) => (
              <label key={r.value} className={role === r.value ? 'active' : ''}>
                <input
                  type="radio"
                  name="role"
                  value={r.value}
                  checked={role === r.value}
                  onChange={() => setRole(r.value)}
                />
                <span>
                  <b>{t(r.labelKey)}</b>
                  <span className="fainttext">{t(r.hintKey)}</span>
                </span>
              </label>
            ))}
          </fieldset>

          {role === 'staff' && (
            <label>
              {t(`admin.team.calendarColumn`)}
              <select value={staffId} onChange={(e) => setStaffId(e.target.value)}>
                <option value="">{t(`admin.team.noCalendar`)}</option>
                {staff.map((s) => (
                  <option key={s.id} value={s.id}>{s.name}</option>
                ))}
              </select>
            </label>
          )}

          <div className="modal-actions">
            <button className="btn" onClick={onClose}>{t(`common.cancel`)}</button>
            <button className="btn btn-primary" disabled={busy || !phone.trim()} onClick={send}>
              {busy ? 'Sending…' : t('admin.team.sendInvite')}
            </button>
          </div>
        </div>
      )}
    </Modal>
  );
}
