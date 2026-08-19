// Catalog: categories and services with staff assignment, in every language
// the salon sells in (E7-T7 / F0.11).
import { useState } from 'react';
import { useTranslation } from 'react-i18next';
import { gql } from '../lib/gql';
import type { Service } from '../lib/types';
import { useAppData } from './AdminLayout';
import { Modal, useToast } from '../components/ui';
import { Icon } from '../lib/icons';
import { LOCALES, LOCALE_NAMES, type Locale } from '../lib/i18n';
import { centsToMad, fmtDur, fmtMAD, madToCents } from '../lib/format';

/** `{ fr: { name, description }, ar: … }` as the API sends and accepts it. */
type Translations = Partial<Record<Locale, Record<string, string>>>;

const valueAt = (translations: Translations, locale: Locale, field: string) =>
  translations[locale]?.[field] ?? '';

/**
 * Writes one field of one locale, dropping the locale entirely when it empties.
 *
 * The emptying matters: an owner clearing the Arabic name means "fall back to
 * French again", and sending `{"ar": {"name": ""}}` instead would pin an empty
 * string in front of the fallback. The server drops blanks too — this keeps the
 * form's own state honest so the tab looks the way it will behave.
 */
function setTranslation(
  translations: Translations,
  locale: Locale,
  field: string,
  value: string,
): Translations {
  const next = { ...(translations[locale] ?? {}) };
  if (value.trim()) next[field] = value;
  else delete next[field];

  const out = { ...translations };
  if (Object.keys(next).length) out[locale] = next;
  else delete out[locale];
  return out;
}

export default function CatalogPage() {
  const { categories, services, staff, refresh } = useAppData();
  const { t } = useTranslation();
  const [editing, setEditing] = useState<Service | 'new' | null>(null);
  const [newCat, setNewCat] = useState(false);

  return (
    <>
      <div className="page-head">
        <h1>{t('admin.catalog.title')}</h1><div className="grow" />
        <button className="btn" onClick={() => setNewCat(true)}>
          <Icon name="plus" size={16} /> {t('admin.catalog.newCategory')}
        </button>
        <button className="btn btn-primary" onClick={() => setEditing('new')}>
          <Icon name="plus" size={16} /> {t('admin.catalog.newService')}
        </button>
      </div>
      {categories.map((cat) => {
        const svcs = services.filter((s) => s.categoryId === cat.id);
        return (
          <div key={cat.id} className="card" style={{ marginBottom: 16 }}>
            <div className="pad" style={{ paddingBottom: 0 }}><h2 style={{ fontSize: 16 }}>{cat.name}</h2></div>
            <table className="list">
              <thead><tr>
                <th>{t('admin.calendar.service')}</th>
                <th>{t('common.duration')}</th>
                <th className="num">{t('common.price')}</th>
                <th>{t('admin.catalog.whoPerforms')}</th>
                <th></th>
              </tr></thead>
              <tbody>
                {svcs.map((s) => (
                  <tr key={s.id} className={s.active ? '' : 'mutetext'}>
                    <td><b>{s.name}</b>
                      {!s.active && <> <span className="badge cancelled">{t('admin.catalog.hidden')}</span></>}
                      <div className="fainttext">{s.description}</div>
                    </td>
                    <td>{fmtDur(s.durationMin)}</td>
                    <td className="num">{fmtMAD(s.priceCents)}</td>
                    <td>
                      <span className="chip-row">
                        {staff.filter((st) => st.serviceIds.includes(s.id)).map((st) => (
                          <span key={st.id} className="dot" title={st.name} style={{ background: st.color }} />
                        ))}
                      </span>
                    </td>
                    <td className="num">
                      <button className="btn btn-sm" onClick={() => setEditing(s)}>
                        {t('common.edit')}
                      </button>
                    </td>
                  </tr>
                ))}
                {svcs.length === 0 && (
                  <tr><td colSpan={5} className="empty">{t('admin.catalog.empty')}</td></tr>
                )}
              </tbody>
            </table>
          </div>
        );
      })}
      {editing && <ServiceModal service={editing === 'new' ? null : editing}
        onClose={() => setEditing(null)} onDone={() => { setEditing(null); refresh(); }} />}
      {newCat && <NewCategoryModal onClose={() => setNewCat(false)}
        onDone={() => { setNewCat(false); refresh(); }} />}
    </>
  );
}

/**
 * Per-locale inputs, one tab each.
 *
 * The French tab is not special here even though it is special in the database
 * — `translations.fr` writes the base column server-side. Making the editor
 * aware of that would leak storage into the UI for no benefit: the owner's
 * model is "the name, in each language I sell in", and that is what this is.
 */
function TranslationTabs({
  fields,
  translations,
  onChange,
}: {
  fields: { key: string; label: string; textarea?: boolean }[];
  translations: Translations;
  onChange: (next: Translations) => void;
}) {
  const { t } = useTranslation();
  const [tab, setTab] = useState<Locale>('fr');

  return (
    <div className="i18n-tabs">
      <div className="i18n-tablist" role="tablist" aria-label={t('admin.catalog.translationsTitle')}>
        {LOCALES.map((code) => {
          // A dot on tabs that hold something, so an owner can see at a glance
          // which languages they have actually filled in.
          const filled = fields.some((f) => valueAt(translations, code, f.key));
          return (
            <button
              key={code}
              type="button"
              role="tab"
              lang={code}
              aria-selected={tab === code}
              className={tab === code ? 'active' : ''}
              onClick={() => setTab(code)}
            >
              {LOCALE_NAMES[code]}
              {filled && <span className="i18n-filled" aria-hidden="true" />}
            </button>
          );
        })}
      </div>

      {fields.map((field) => (
        <div key={field.key}>
          <label>{field.label}</label>
          {field.textarea ? (
            <textarea
              rows={2}
              // The input has to be typed in the language of its tab, whatever
              // the interface language is — otherwise an Arabic name typed into
              // an LTR box has its punctuation land at the wrong end.
              lang={tab}
              dir={tab === 'ar' ? 'rtl' : 'ltr'}
              value={valueAt(translations, tab, field.key)}
              onChange={(e) => onChange(setTranslation(translations, tab, field.key, e.target.value))}
            />
          ) : (
            <input
              lang={tab}
              dir={tab === 'ar' ? 'rtl' : 'ltr'}
              value={valueAt(translations, tab, field.key)}
              onChange={(e) => onChange(setTranslation(translations, tab, field.key, e.target.value))}
            />
          )}
        </div>
      ))}

      <div className="fainttext i18n-hint">{t('admin.catalog.translationsHint')}</div>
    </div>
  );
}

function ServiceModal({ service, onClose, onDone }:
  { service: Service | null; onClose: () => void; onDone: () => void }) {
  const { categories, staff } = useAppData();
  const { t } = useTranslation();
  const toast = useToast();
  const [translations, setTranslations] = useState<Translations>(
    (service?.translations as Translations) ?? {},
  );
  const [f, setF] = useState({
    categoryId: service?.categoryId ?? categories[0]?.id ?? '',
    durationMin: service?.durationMin ?? 60,
    // Held as MAD because that is what the owner types; converted to centimes
    // at the API boundary.
    priceMad: service ? centsToMad(service.priceCents) : 200,
    active: service?.active ?? true,
  });
  const [staffIds, setStaffIds] = useState<string[]>(
    service ? staff.filter((st) => st.serviceIds.includes(service.id)).map((st) => st.id) : []);
  const [err, setErr] = useState('');

  // French is what the fallback chain ends at, so it is the one language a
  // service cannot be sold without.
  const frenchName = valueAt(translations, 'fr', 'name');

  const save = async () => {
    try {
      if (!frenchName.trim()) throw new Error(t('admin.catalog.frenchNameRequired'));
      const { priceMad, ...rest } = f;
      const vars = {
        ...rest,
        // `name` is still sent because it is `non_null` on create; the server
        // then lets `translations.fr` win, which is the same value.
        name: frenchName,
        translations,
        priceCents: madToCents(priceMad),
        staffIds,
      };

      if (service) {
        await gql(
          `mutation($id: ID!, $categoryId: ID, $name: String, $translations: Json,
            $durationMin: Int, $priceCents: Int, $active: Boolean, $staffIds: [ID!]) {
            updateService(id: $id, categoryId: $categoryId, name: $name,
              translations: $translations, durationMin: $durationMin, priceCents: $priceCents,
              active: $active, staffIds: $staffIds) { id } }`,
          { id: service.id, ...vars });
      } else {
        await gql(
          `mutation($categoryId: ID!, $name: String!, $translations: Json,
            $durationMin: Int!, $priceCents: Int!, $staffIds: [ID!]) {
            createService(categoryId: $categoryId, name: $name, translations: $translations,
              durationMin: $durationMin, priceCents: $priceCents, staffIds: $staffIds) { id } }`,
          vars);
      }
      toast(t('common.saved'));
      onDone();
    } catch (e) { setErr((e as Error).message); }
  };

  return (
    <Modal onClose={onClose}>
      <h2>{service ? t('admin.catalog.editService') : t('admin.catalog.newService')}</h2>

      <TranslationTabs
        fields={[
          { key: 'name', label: t('admin.catalog.serviceName') },
          { key: 'description', label: t('admin.catalog.description'), textarea: true },
        ]}
        translations={translations}
        onChange={setTranslations}
      />

      <div className="grid2">
        <div><label>{t('admin.catalog.categoryName')}</label>
          <select value={f.categoryId} onChange={(e) => setF({ ...f, categoryId: e.target.value })}>
            {categories.map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}
          </select>
        </div>
        <div><label>{t('common.duration')}</label>
          <select value={f.durationMin} onChange={(e) => setF({ ...f, durationMin: Number(e.target.value) })}>
            {[15, 30, 45, 60, 75, 90, 120, 150, 180].map((m) => <option key={m} value={m}>{fmtDur(m)}</option>)}
          </select>
        </div>
      </div>
      <label>{t('admin.catalog.priceMad')}</label>
      <input type="number" step="0.01" min="0" value={f.priceMad}
        onChange={(e) => setF({ ...f, priceMad: Number(e.target.value) })} />
      <label>{t('admin.catalog.whoPerforms')}</label>
      <div className="checkgrid">
        {staff.filter((s) => s.active).map((st) => (
          <label key={st.id}>
            <input type="checkbox" className="toggle-switch" checked={staffIds.includes(st.id)}
              onChange={(e) => setStaffIds(e.target.checked
                ? [...staffIds, st.id] : staffIds.filter((x) => x !== st.id))} />
            <span className="dot" style={{ background: st.color }} />{st.name}
          </label>
        ))}
      </div>
      {service && (
        <label style={{ marginTop: 14, display: 'flex', gap: 7, alignItems: 'center' }}>
          <input type="checkbox" className="toggle-switch" checked={f.active}
            onChange={(e) => setF({ ...f, active: e.target.checked })} />
          {t('admin.catalog.bookableOnline')}
        </label>
      )}
      <div className="err">{err}</div>
      <div className="actions">
        <button className="btn" onClick={onClose}>{t('common.cancel')}</button>
        <button className="btn btn-primary" onClick={save}>{t('common.save')}</button>
      </div>
    </Modal>
  );
}

function NewCategoryModal({ onClose, onDone }: { onClose: () => void; onDone: () => void }) {
  const { t } = useTranslation();
  const [translations, setTranslations] = useState<Translations>({});
  const name = valueAt(translations, 'fr', 'name');

  return (
    <Modal onClose={onClose}>
      <h2>{t('admin.catalog.newCategory')}</h2>
      <TranslationTabs
        fields={[{ key: 'name', label: t('admin.catalog.categoryName') }]}
        translations={translations}
        onChange={setTranslations}
      />
      <div className="actions">
        <button className="btn" onClick={onClose}>{t('common.cancel')}</button>
        <button className="btn btn-primary" onClick={async () => {
          if (!name.trim()) return;
          await gql(
            'mutation($name: String!, $translations: Json) { createCategory(name: $name, translations: $translations) { id } }',
            { name, translations },
          );
          onDone();
        }}>{t('common.add')}</button>
      </div>
    </Modal>
  );
}
