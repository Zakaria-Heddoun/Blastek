// Who can sign in to this venue, and at what level (E4-T4 / F0.3).
//
// Deliberately separate from the staff roster next to it: a `staff` row is a
// calendar column that takes appointments, a membership is a login. Most people
// are both, some are only one — a silent partner who sees the books but never
// holds scissors, a junior who is booked but has no dashboard account — and
// merging the two concepts is what makes "remove their access" accidentally
// delete a year of appointments.
import { useCallback, useEffect, useState } from 'react';
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
  { value: 'owner', label: 'Owner', hint: 'Everything, including the team and billing.' },
  { value: 'manager', label: 'Manager', hint: 'Catalog, team roster, sales and reports.' },
  { value: 'receptionist', label: 'Receptionist', hint: 'Calendar, clients and checkout. No revenue.' },
  { value: 'staff', label: 'Staff', hint: 'Their own calendar and their own clients.' },
];

const roleLabel = (value: string) => ROLES.find((r) => r.value === value)?.label ?? value;

export default function MembersTab({ staff }: { staff: Staff[] }) {
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
          <h2 style={{ fontSize: 16, margin: 0 }}>Access</h2>
          <p className="mutetext" style={{ margin: '4px 0 0', fontSize: 13 }}>
            People who can sign in to this venue. Removing someone takes their access away and
            keeps their appointments.
          </p>
        </div>
        <div className="grow" />
        <button className="btn btn-primary" onClick={() => setInviting(true)}>
          <Icon name="plus" size={16} /> Invite
        </button>
      </div>

      {members === null && <div className="empty">Loading…</div>}

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
                    'Invited member'}
                </b>
                {isMe && <span className="member-you">You</span>}
                <div className="fainttext">
                  {member.user?.email || member.user?.phone || '—'}
                  {member.staffId && ' · has a calendar'}
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
                    'Role updated',
                  )
                }
              >
                {ROLES.map((r) => (
                  <option key={r.value} value={r.value}>{r.label}</option>
                ))}
              </select>

              <button
                className="btn btn-sm btn-danger"
                disabled={busy || lastOwner}
                title={lastOwner ? 'A venue must keep at least one owner' : undefined}
                onClick={() =>
                  act(
                    `mutation($id: ID!) { removeMember(id: $id) { id } }`,
                    { id: member.id },
                    'Access removed',
                  )
                }
              >
                Remove
              </button>
            </div>
          );
        })}
      </div>

      {invitations.length > 0 && (
        <>
          <h2 className="section-title" style={{ fontSize: 15 }}>Pending invitations</h2>
          <div className="member-rows">
            {invitations.map((invitation) => (
              <div key={invitation.id} className="card pad member-row is-pending">
                <div className="grow">
                  <b>{invitation.phone || invitation.email}</b>
                  <div className="fainttext">
                    Invited as {roleLabel(invitation.role)} · expires{' '}
                    {new Date(`${invitation.expiresAt}Z`).toLocaleDateString()}
                  </div>
                </div>
                <button
                  className="btn btn-sm"
                  disabled={busy}
                  onClick={() =>
                    act(
                      `mutation($id: ID!) { revokeInvitation(id: $id) { id } }`,
                      { id: invitation.id },
                      'Invitation withdrawn',
                    )
                  }
                >
                  Withdraw
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
      toast(d.inviteMember.delivered ? 'Invitation sent' : 'Invitation created');
    } catch (e) {
      toast((e as Error).message, true);
    } finally {
      setBusy(false);
    }
  };

  return (
    <Modal onClose={link ? onDone : onClose}>
      <h2 style={{ fontSize: 17, margin: '0 0 14px' }}>Invite a team member</h2>
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
          <button className="btn btn-primary" onClick={onDone}>Done</button>
        </div>
      ) : (
        <div className="invite-form">
          <label>
            Mobile number
            <input
              type="tel"
              inputMode="tel"
              placeholder="06 12 34 56 78"
              value={phone}
              onChange={(e) => setPhone(e.target.value)}
            />
          </label>

          <fieldset className="invite-roles">
            <legend>Role</legend>
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
                  <b>{r.label}</b>
                  <span className="fainttext">{r.hint}</span>
                </span>
              </label>
            ))}
          </fieldset>

          {role === 'staff' && (
            <label>
              Calendar column (optional)
              <select value={staffId} onChange={(e) => setStaffId(e.target.value)}>
                <option value="">No calendar — dashboard access only</option>
                {staff.map((s) => (
                  <option key={s.id} value={s.id}>{s.name}</option>
                ))}
              </select>
            </label>
          )}

          <div className="modal-actions">
            <button className="btn" onClick={onClose}>Cancel</button>
            <button className="btn btn-primary" disabled={busy || !phone.trim()} onClick={send}>
              {busy ? 'Sending…' : 'Send invitation'}
            </button>
          </div>
        </div>
      )}
    </Modal>
  );
}
