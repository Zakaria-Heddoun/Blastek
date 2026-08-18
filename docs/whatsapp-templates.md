# WhatsApp template approval pack

**E6-T9 / F0.10.** The copy submitted to Meta for approval, and the mapping
between an approved template and `Blastek.Notifications.Templates`.

## Why this document exists

Meta only permits free-form WhatsApp messages inside a 24-hour window opened by
the *customer* messaging the business. Blastek messages first, so every
launch flow needs a **pre-approved template**: a fixed body with numbered
placeholders, reviewed by Meta per language, referenced by name.

That has three consequences worth stating plainly:

1. **Copy changes need re-approval.** A template edited in code but not
   resubmitted will be rejected at send time and fall through to SMS. Ship copy
   changes and template submissions together.
2. **Placeholders are positional.** `{{1}}` is whatever the code passes first.
   Reordering a sentence in translation is fine; reordering the *parameters* is
   a bug that reads perfectly in review and produces "Reminder: Le Salon Anfa at
   Coupe" in production.
3. **Approval is per language.** French and Arabic are separate submissions
   under the same template name. Until both are approved, the unapproved one
   falls back to SMS — which works, and costs money.

## Category

Most of these are **UTILITY**, not MARKETING. Each is the direct consequence of
something the recipient did: they booked, they cancelled, they asked for a
code. Submitting a reminder as MARKETING invites both a rejection and a
per-message price rise.

**The two review templates are the exception, and they are the ones to think
about before submitting.** A review request is not the consequence of anything
the customer did — it is us asking them for something. Meta has rejected
review solicitations submitted as UTILITY, and the honest reading of their
policy puts these under MARKETING.

Submit them as MARKETING. It costs more per message and it requires marketing
opt-in, which is why `Blastek.Notifications.Templates` already files them under
the `:reminders` preference rather than as transactional: a customer who has
switched messages off gets no review request, and that was decided in the code
before it was decided here. If Meta approves them as UTILITY, nothing in the
application needs to change — the preference is ours, not theirs.

## Status

Not yet submitted. `Blastek.Notifications.Providers.WhatsApp` reads approved
template names from `config :blastek, :whatsapp_templates`, which is empty until
Meta approves them — so today every WhatsApp send is attempted as free-form
text, fails outside a session window, and falls through to SMS. That is the
intended interim behaviour, not an outage.

Once a template is approved, add it:

```elixir
config :blastek, :whatsapp_templates, %{
  booking_confirmed_customer: {"blastek_booking_confirmed", [:venue, :service, :when, :staff]},
  reminder_24h: {"blastek_reminder_24h", [:service, :venue, :when]}
}
```

---

## The templates

### `blastek_booking_confirmed` — booking confirmed, to the customer

| # | Parameter | Example |
|---|---|---|
| 1 | Venue name | Le Salon Anfa |
| 2 | Service | Coupe femme |
| 3 | Date and time | samedi 2 août à 14:30 |
| 4 | Staff member | Yasmine |

**fr** — Réservation confirmée chez {{1}} : {{2}} le {{3}} avec {{4}}.

**ar** — تم تأكيد حجزك في {{1}}: {{2}} يوم {{3}} مع {{4}}.

**en** — Booking confirmed at {{1}}: {{2}} on {{3}} with {{4}}.

---

### `blastek_booking_requested` — request received, salon still to confirm

Sent instead of the above when the venue has `instant_confirmation` off. Saying
"confirmed" to somebody whose appointment nobody has looked at is the small lie
that produces a phone call.

| # | Parameter | Example |
|---|---|---|
| 1 | Venue name | Le Salon Anfa |
| 2 | Service | Coupe femme |
| 3 | Date and time | samedi 2 août à 14:30 |

**fr** — Demande reçue chez {{1}} : {{2}} le {{3}}. Le salon confirme sous peu.

**ar** — تم استلام طلبك في {{1}}: {{2}} يوم {{3}}. سيؤكد الصالون قريبًا.

**en** — Request received at {{1}}: {{2}} on {{3}}. The salon will confirm shortly.

---

### `blastek_new_booking_salon` — new online booking, to the salon

| # | Parameter | Example |
|---|---|---|
| 1 | Client name | Leila Bennani |
| 2 | Service | Coupe femme |
| 3 | Date and time | samedi 2 août à 14:30 |
| 4 | Staff member | Yasmine |

**fr** — Nouvelle réservation en ligne : {{1}}, {{2}} le {{3}} ({{4}}).

**ar** — حجز جديد عبر الإنترنت: {{1}}، {{2}} يوم {{3}} ({{4}}).

**en** — New online booking: {{1}}, {{2}} on {{3}} ({{4}}).

---

### `blastek_reminder_24h` — the evening before

Carries a **URL button** (Cancel), not a body placeholder: Meta renders buttons
as tappable, and a bare URL inside the body of a WhatsApp template is not
clickable on every client.

| # | Parameter | Example |
|---|---|---|
| 1 | Service | Coupe femme |
| 2 | Venue name | Le Salon Anfa |
| 3 | Time | 14:30 |
| 4 | Staff member | Yasmine |
| Button URL suffix | Signed action token | `a/cancel/SFMyNTY…` |

**fr** — Rappel : {{1}} chez {{2}} demain à {{3}} avec {{4}}.
Bouton : *Annuler*

**ar** — تذكير: {{1}} في {{2}} غدًا على {{3}} مع {{4}}.
الزر: *إلغاء*

**en** — Reminder: {{1}} at {{2}} tomorrow at {{3}} with {{4}}.
Button: *Cancel*

---

### `blastek_reminder_3h` — a few hours before

| # | Parameter | Example |
|---|---|---|
| 1 | Service | Coupe femme |
| 2 | Venue name | Le Salon Anfa |
| 3 | Time | 14:30 |

**fr** — À tout à l'heure : {{1}} chez {{2}} à {{3}}.

**ar** — نراك قريبًا: {{1}} في {{2}} على {{3}}.

**en** — See you soon: {{1}} at {{2}} at {{3}}.

---

### `blastek_cancelled_by_customer` — to the salon

| # | Parameter | Example |
|---|---|---|
| 1 | Client name | Leila Bennani |
| 2 | Service | Coupe femme |
| 3 | Date and time | samedi 2 août à 14:30 |

**fr** — Annulation : {{1}} a annulé {{2}} du {{3}}. Le créneau est libre.

**ar** — إلغاء: {{1}} ألغى {{2}} ليوم {{3}}. الموعد متاح الآن.

**en** — Cancellation: {{1}} cancelled {{2}} on {{3}}. The slot is free.

---

### `blastek_cancelled_by_salon` — to the customer

| # | Parameter | Example |
|---|---|---|
| 1 | Venue name | Le Salon Anfa |
| 2 | Date and time | samedi 2 août à 14:30 |
| 3 | Venue phone | +212 5 22 27 48 80 |

**fr** — {{1}} a dû annuler votre rendez-vous du {{2}}. Appelez le salon pour replanifier : {{3}}.

**ar** — {{1}} اضطر لإلغاء موعدك يوم {{2}}. اتصل بالصالون لإعادة الحجز: {{3}}.

**en** — {{1}} had to cancel your appointment on {{2}}. Call the salon to rebook: {{3}}.

---

### `blastek_rescheduled` — to the customer

| # | Parameter | Example |
|---|---|---|
| 1 | Venue name | Le Salon Anfa |
| 2 | New date and time | mardi 5 août à 10:00 |
| 3 | Staff member | Yasmine |

**fr** — Votre rendez-vous chez {{1}} est déplacé au {{2}} avec {{3}}.

**ar** — تم نقل موعدك في {{1}} إلى {{2}} مع {{3}}.

**en** — Your appointment at {{1}} has moved to {{2}} with {{3}}.

---

### `blastek_review_invite` — two hours after the visit

Carries a **URL button** (Leave a review) for the same reason the reminders do:
a bare URL in a template body is not tappable on every client, and this link is
the entire point of the message.

Sent once, at T+2h. See `Blastek.Notifications.ReviewInvites`.

| # | Parameter | Example |
|---|---|---|
| 1 | Venue name | Le Salon Anfa |
| Button URL suffix | Signed review token | `review/SFMyNTY…` |

**fr** — Merci de votre visite chez {{1}} ! Comment ça s'est passé ?
Bouton : *Donner mon avis*

**ar** — شكرًا لزيارتك {{1}}! كيف كانت التجربة؟
الزر: *اترك تقييمًا*

**en** — Thanks for visiting {{1}}! How did it go?
Button: *Leave a review*

---

### `blastek_review_reminder` — the one and only follow-up

Sent at T+24h, and **only if the customer has not answered** — the job re-reads
that as it fires, so a review left at T+3h cancels this. There is no third
message; F0.8 caps it here, and a salon that nags is a salon customers mute,
which also loses them the reminders that stop no-shows.

| # | Parameter | Example |
|---|---|---|
| 1 | Venue name | Le Salon Anfa |
| Button URL suffix | Signed review token | `review/SFMyNTY…` |

**fr** — Un avis sur {{1}} ? Une minute suffit.
Bouton : *Donner mon avis*

**ar** — رأيك في {{1}}؟ دقيقة واحدة تكفي.
الزر: *اترك تقييمًا*

**en** — A quick word about {{1}}? One minute.
Button: *Leave a review*

---

### `blastek_code` — one-time code

Submit under Meta's **AUTHENTICATION** category, not UTILITY: it has its own
review path, its own rate allowances, and its own copy-once button. Meta
restricts the body of an authentication template, so the wording below is
the closest permitted form rather than a free choice.

| # | Parameter | Example |
|---|---|---|
| 1 | Code | 123456 |

**fr** — {{1}} est votre code de vérification.

**ar** — {{1}} هو رمز التحقق الخاص بك.

**en** — {{1}} is your verification code.

---

## Arabic review notes

The Arabic strings above are what `Templates.render/3` produces **minus the
direction isolates**. In the running system every interpolated value is wrapped
in `U+2066 … U+2069` so a Latin salon name or a `14:30` keeps its own direction
inside a right-to-left sentence — without them, "Le Salon Anfa" can render with
its words reordered and a time can come out as `30:14`.

Meta's template editor should receive the strings *without* the isolates: the
placeholders are theirs, and they apply their own bidi handling to the values
they substitute.

Moroccan month names are used rather than Levantine ones — غشت, not أغسطس —
because that is what the market reads. See
`Blastek.Notifications.Format`.
