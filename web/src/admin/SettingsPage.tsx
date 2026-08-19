// Everything an owner controls about how their venue works and appears
// (E5-T5 / F0.4, extending the photos-and-pin page E8 left behind).
//
// Ordered the way an owner thinks about it: who we are, what we look like,
// where we are, when we are open, and how booking behaves.
import { useCallback, useEffect, useRef, useState } from 'react';
import { useTranslation } from 'react-i18next';
import { gql } from '../lib/gql';
import type { Photo, UploadTicket, VenueSummary } from '../lib/types';
import { Icon } from '../lib/icons';
import { useToast } from '../components/ui';
import VenueMap from '../components/VenueMap';
import ScheduleSettings from './ScheduleSettings';
import { useAppData } from './AdminLayout';
import './admin.css';

const LOAD = `{
  venuePhotos { id alt kind sort status width height urls { original thumb card hero } }
  currentVenue {
    id name city address phone tagline lat lng womenOnly status settingsJson
  }
}`;

const UPDATE_VENUE = `mutation($input: VenueInput!) {
  updateVenue(input: $input) { id name tagline address city phone }
}`;

const UPDATE_SETTINGS = `mutation($input: VenueSettingsInput!) {
  updateVenueSettings(input: $input) { id settingsJson }
}`;

const REQUEST_UPLOAD = `mutation($contentType: String!, $byteSize: Int) {
  requestPhotoUpload(contentType: $contentType, byteSize: $byteSize) {
    url
    headers { name value }
    photo { id }
  }
}`;

const FINALIZE = `mutation($id: ID!) {
  finalizePhotoUpload(id: $id) { id status urls { thumb card } }
}`;

const DELETE = `mutation($id: ID!) { deletePhoto(id: $id) { id } }`;
const SET_COVER = `mutation($id: ID!) { setCoverPhoto(id: $id) { id kind } }`;
const REORDER = `mutation($ids: [ID!]!) { reorderPhotos(ids: $ids) { id sort } }`;

const SET_LOCATION = `mutation($lat: Float!, $lng: Float!) {
  setVenueLocation(lat: $lat, lng: $lng) { id lat lng }
}`;

const GEOCODE = `mutation($force: Boolean) {
  geocodeVenue(force: $force) { id lat lng }
}`;

const SET_WOMEN_ONLY = `mutation($value: Boolean!) {
  setVenueWomenOnly(value: $value) { id }
}`;

const ACCEPTED = 'image/jpeg,image/png,image/webp';
const MAX_BYTES = 10 * 1024 * 1024;

export default function SettingsPage() {
  const { t } = useTranslation();
  const { settings } = useAppData();
  const toast = useToast();

  const [photos, setPhotos] = useState<Photo[] | null>(null);
  const [venue, setVenue] = useState<VenueSummary | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const fileInput = useRef<HTMLInputElement>(null);

  const load = useCallback(async () => {
    try {
      const d = await gql<{ venuePhotos: Photo[]; currentVenue: VenueSummary }>(LOAD);
      setPhotos(d.venuePhotos ?? []);
      setVenue(d.currentVenue);
    } catch (e) {
      setError((e as Error).message);
    }
  }, []);

  useEffect(() => {
    document.title = t('admin.settings.pageTitle');
    load();
  }, [load]);

  /**
   * The three-step upload: ask for a presigned PUT, send the bytes straight to
   * storage, then tell the API to validate and build variants.
   *
   * Errors are reported per file rather than aborting the batch — one rejected
   * photo should not discard four good ones.
   */
  const upload = async (files: FileList) => {
    setBusy(true);
    setError('');

    for (const file of Array.from(files)) {
      if (file.size > MAX_BYTES) {
        toast(`${file.name} is larger than 10 MB`);
        continue;
      }

      try {
        const { requestPhotoUpload: ticket } = await gql<{ requestPhotoUpload: UploadTicket }>(
          REQUEST_UPLOAD,
          { contentType: file.type, byteSize: file.size },
        );

        // Straight to storage — the bytes never pass through the API. Every
        // signed header has to be replayed or the signature will not match.
        const headers = Object.fromEntries(ticket.headers.map((h) => [h.name, h.value]));
        const put = await fetch(ticket.url, { method: 'PUT', headers, body: file });
        if (!put.ok) throw new Error(`Upload failed (${put.status})`);

        await gql(FINALIZE, { id: ticket.photo.id });
      } catch (e) {
        toast(`${file.name}: ${(e as Error).message}`);
      }
    }

    setBusy(false);
    if (fileInput.current) fileInput.current.value = '';
    await load();
  };

  const act = async (query: string, variables: Record<string, unknown>, done: string) => {
    setBusy(true);
    try {
      await gql(query, variables);
      toast(done);
      await load();
    } catch (e) {
      toast((e as Error).message);
    } finally {
      setBusy(false);
    }
  };

  const move = (photo: Photo, delta: number) => {
    if (!photos) return;
    const ordered = photos.filter((p) => p.status === 'ready');
    const from = ordered.findIndex((p) => p.id === photo.id);
    const to = from + delta;
    if (from < 0 || to < 0 || to >= ordered.length) return;

    const next = [...ordered];
    [next[from], next[to]] = [next[to], next[from]];
    act(REORDER, { ids: next.map((p) => p.id) }, t('admin.settings.orderSaved'));
  };

  const pinned = venue?.lat != null && venue?.lng != null;

  return (
    <div>
      <div className="page-head">
        <div>
          <h1>{t(`admin.settings.title`)}</h1>
          <p className="mutetext">
            How {settings.businessName} appears to shoppers on the marketplace.
          </p>
        </div>
        <div className="grow" />
      </div>

      {error && <div className="empty">{error}</div>}

      {venue && <IdentitySection venue={venue} onSaved={load} />}

      <section className="card pad set-section">
        <div className="set-section-head">
          <h2>{t(`admin.settings.photos`)}</h2>
          <p className="mutetext">
            {t(`admin.settings.photosBody`)}
          </p>
        </div>

        <input
          ref={fileInput}
          type="file"
          accept={ACCEPTED}
          multiple
          disabled={busy}
          onChange={(e) => e.target.files?.length && upload(e.target.files)}
        />

        {photos === null && <div className="empty">{t(`common.loading`)}</div>}
        {photos?.length === 0 && (
          <div className="empty">
            {t(`admin.settings.noPhotos`)}
          </div>
        )}

        <div className="photo-grid">
          {photos?.map((photo, index) => (
            <figure key={photo.id} className={`photo-tile${photo.kind === 'cover' ? ' is-cover' : ''}`}>
              {photo.status === 'ready' ? (
                <img src={photo.urls?.thumb || photo.urls?.original} alt={photo.alt || ''} />
              ) : (
                <div className={`photo-placeholder is-${photo.status}`}>
                  {photo.status === 'failed' ? 'Rejected' : 'Processing…'}
                </div>
              )}

              <figcaption>
                {photo.kind === 'cover' && <span className="photo-badge">{t(`admin.settings.cover`)}</span>}

                <div className="photo-actions">
                  {photo.status === 'ready' && photo.kind !== 'cover' && (
                    <button
                      className="btn btn-sm"
                      disabled={busy}
                      onClick={() => act(SET_COVER, { id: photo.id }, t('admin.settings.coverUpdated'))}
                    >
                      {t(`admin.settings.makeCover`)}
                    </button>
                  )}
                  {photo.status === 'ready' && (
                    <>
                      <button
                        className="icon-btn"
                        aria-label={t(`admin.settings.moveEarlier`)}
                        disabled={busy || index === 0}
                        onClick={() => move(photo, -1)}
                      >
                        <Icon name="left" size={14} />
                      </button>
                      <button
                        className="icon-btn"
                        aria-label={t(`admin.settings.moveLater`)}
                        disabled={busy}
                        onClick={() => move(photo, 1)}
                      >
                        <Icon name="right" size={14} />
                      </button>
                    </>
                  )}
                  <button
                    className="btn btn-sm btn-danger"
                    disabled={busy}
                    onClick={() => act(DELETE, { id: photo.id }, t('admin.settings.photoDeleted'))}
                  >
                    {t(`common.delete`)}
                  </button>
                </div>
              </figcaption>
            </figure>
          ))}
        </div>
      </section>

      <section className="card pad set-section">
        <div className="set-section-head">
          <h2>{t(`admin.settings.location`)}</h2>
          <p className="mutetext">
            {t(`admin.settings.locationBody`)}
          </p>
        </div>

        <div className="set-loc-actions">
          <button
            className="btn btn-sm"
            disabled={busy || !venue}
            onClick={() => act(GEOCODE, { force: pinned }, t('admin.settings.locatedFromAddress'))}
          >
            <Icon name="pin" size={14} /> {pinned ? t('admin.settings.relocate') : t('admin.settings.findFromAddress')}
          </button>
          <span className="fainttext">
            {/* An unloaded venue and a genuinely unpinned one are different states;
                conflating them tells an owner with a pin that they have none. */}
            {!venue
              ? t('admin.settings.loadingLocation')
              : pinned
                ? `Pinned at ${venue.lat?.toFixed(5)}, ${venue.lng?.toFixed(5)}`
                : t('admin.settings.noPin')}
          </span>
        </div>

        <VenueMap
          markers={
            pinned
              ? [
                  {
                    id: venue?.id ?? 'venue',
                    lat: venue?.lat as number,
                    lng: venue?.lng as number,
                    label: settings.businessName,
                  },
                ]
              : []
          }
          center={pinned ? [venue?.lat as number, venue?.lng as number] : undefined}
          zoom={pinned ? 16 : 12}
          height={320}
          fitToMarkers={false}
          ariaLabel={t(`admin.settings.locationPicker`)}
          onPick={(lat, lng) => act(SET_LOCATION, { lat, lng }, t('admin.settings.pinMoved'))}
        />
      </section>

      <ScheduleSettings />

      {venue && <BookingRulesSection venue={venue} onSaved={load} />}

      <section className="card pad set-section">
        <div className="set-section-head">
          <h2>{t(`admin.settings.listing`)}</h2>
        </div>

        <label className="set-toggle">
          <input
            type="checkbox"
            className="toggle-switch"
            disabled={busy || !venue}
            // Controlled from the server's value: an optimistic local toggle
            // would keep showing the new state after a failed write.
            checked={Boolean(venue?.womenOnly)}
            onChange={(e) => act(SET_WOMEN_ONLY, { value: e.target.checked }, t('admin.settings.listingUpdated'))}
          />
          <span>
            <b>{t(`admin.settings.womenOnly`)}</b>
            <span className="fainttext">
              {t(`admin.settings.womenOnlyHint`)}
            </span>
          </span>
        </label>
      </section>
    </div>
  );
}

/** Name, tagline, address — the details customers read. */
function IdentitySection({ venue, onSaved }: { venue: VenueSummary; onSaved: () => void }) {
  const { t } = useTranslation();
  const toast = useToast();
  const [form, setForm] = useState({
    name: venue.name ?? '',
    tagline: venue.tagline ?? '',
    address: venue.address ?? '',
    city: venue.city ?? '',
    phone: venue.phone ?? '',
  });
  const [busy, setBusy] = useState(false);

  const set = (key: keyof typeof form) => (e: React.ChangeEvent<HTMLInputElement>) =>
    setForm((f) => ({ ...f, [key]: e.target.value }));

  const save = async () => {
    if (busy) return;
    setBusy(true);
    try {
      await gql(UPDATE_VENUE, { input: form });
      toast(t('admin.settings.detailsSaved'));
      onSaved();
    } catch (e) {
      toast((e as Error).message, true);
    } finally {
      setBusy(false);
    }
  };

  return (
    <section className="card pad set-section">
      <div className="set-section-head">
        <h2>{t(`admin.settings.yourSalon`)}</h2>
        <p className="mutetext">{t(`admin.settings.yourSalonSub`)}</p>
      </div>

      <div className="identity-form">
        <label>{t(`common.name`)}<input value={form.name} onChange={set('name')} /></label>
        <label>
          {t(`admin.settings.tagline`)}
          <input
            value={form.tagline}
            onChange={set('tagline')}
            placeholder={t(`admin.settings.taglinePlaceholder`)}
          />
        </label>
        <label>{t(`admin.settings.address`)}<input value={form.address} onChange={set('address')} /></label>
        <label>{t(`admin.settings.city`)}<input value={form.city} onChange={set('city')} /></label>
        <label>{t(`admin.settings.phone`)}<input value={form.phone} onChange={set('phone')} /></label>

        <button className="btn btn-primary" disabled={busy || !form.name.trim()} onClick={save}>
          {busy ? 'Saving…' : 'Save'}
        </button>
      </div>
    </section>
  );
}

/**
 * The rules the booking engine actually enforces.
 *
 * Their own section rather than tacked onto the address form: these change what
 * a customer is offered and what they may undo, which is a different decision
 * from fixing a typo in the tagline.
 */
function BookingRulesSection({ venue, onSaved }: { venue: VenueSummary; onSaved: () => void }) {
  const { t } = useTranslation();
  const toast = useToast();
  const s = (venue.settingsJson ?? {}) as Record<string, unknown>;

  const [rules, setRules] = useState({
    slotStepMin: Number(s.slot_step_min ?? 15),
    bookingHorizonDays: Number(s.booking_horizon_days ?? 90),
    bookingLeadMin: Number(s.booking_lead_min ?? 0),
    cancellationWindowHours: Number(s.cancellation_window_hours ?? 24),
    instantConfirmation: s.instant_confirmation !== false,
  });
  const [busy, setBusy] = useState(false);

  const pick = (key: keyof typeof rules) => (e: React.ChangeEvent<HTMLSelectElement>) =>
    setRules((r) => ({ ...r, [key]: Number(e.target.value) }));

  const save = async () => {
    if (busy) return;
    setBusy(true);
    try {
      await gql(UPDATE_SETTINGS, { input: rules });
      toast(t('admin.settings.rulesSaved'));
      onSaved();
    } catch (e) {
      toast((e as Error).message, true);
    } finally {
      setBusy(false);
    }
  };

  return (
    <section className="card pad set-section">
      <div className="set-section-head">
        <h2>{t(`admin.settings.bookingRules`)}</h2>
        <p className="mutetext">
          {t(`admin.settings.rulesBody`)}
        </p>
      </div>

      <div className="identity-form">
        <label>
          {t(`admin.settings.slotEvery`)}
          <select value={rules.slotStepMin} onChange={pick('slotStepMin')}>
            {[5, 10, 15, 20, 30, 60].map((m) => (
              <option key={m} value={m}>{m} minutes</option>
            ))}
          </select>
        </label>

        <label>
          {t(`admin.settings.bookableUpTo`)}
          <select value={rules.bookingHorizonDays} onChange={pick('bookingHorizonDays')}>
            {[14, 30, 60, 90, 180, 365].map((d) => (
              <option key={d} value={d}>{d} days ahead</option>
            ))}
          </select>
        </label>

        <label>
          {t(`admin.settings.noticeNeeded`)}
          <select value={rules.bookingLeadMin} onChange={pick('bookingLeadMin')}>
            <option value={0}>{t(`admin.settings.leadNone`)}</option>
            {[30, 60, 120, 240, 480, 1440].map((m) => (
              <option key={m} value={m}>
                {m < 60 ? `${m} minutes` : `${m / 60} hour${m === 60 ? '' : 's'}`}
              </option>
            ))}
          </select>
        </label>

        <label>
          {t(`admin.settings.cancelUntil`)}
          <select
            value={rules.cancellationWindowHours}
            onChange={pick('cancellationWindowHours')}
          >
            <option value={0}>{t(`admin.settings.cancelAnyTime`)}</option>
            {[2, 4, 12, 24, 48, 72].map((h) => (
              <option key={h} value={h}>{h} hours before</option>
            ))}
          </select>
        </label>

        <label className="set-toggle">
          <input
            type="checkbox"
            className="toggle-switch"
            checked={rules.instantConfirmation}
            onChange={(e) =>
              setRules((r) => ({ ...r, instantConfirmation: e.target.checked }))
            }
          />
          <span>
            {t(`admin.settings.autoConfirm`)}
            <span className="fainttext">
              {t(`admin.settings.autoConfirmHint`)}
            </span>
          </span>
        </label>

        <button className="btn btn-primary" disabled={busy} onClick={save}>
          {busy ? 'Saving…' : 'Save'}
        </button>
      </div>
    </section>
  );
}
