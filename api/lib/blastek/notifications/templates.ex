defmodule Blastek.Notifications.Templates do
  @moduledoc """
  The message copy, in French, Arabic and English (E6-T2, E6-T9 / F0.10).

  In code rather than in the database, deliberately. A venue does not write its
  own transactional copy — the WhatsApp variants are approved by Meta against a
  fixed body with numbered placeholders, and a template a venue could edit is a
  template Meta would have to re-approve on every edit. Copy changes ship with
  the code that sends them.

  French is the default and Arabic is a first-class peer; English is the
  fallback for neither. That ordering is the product: the market is Morocco.

  ## Arabic and interpolation

  Arabic is right-to-left, and a Latin name or a bare number dropped into an RTL
  sentence renders in whatever order the reader's shaping engine decides.
  `\\u2066…\\u2069` (FIRST STRONG ISOLATE / POP DIRECTIONAL ISOLATE) wraps every
  interpolated value so a salon called "Le Salon Anfa" and a time of "14:30"
  land where the sentence puts them rather than migrating across it. See
  `isolate/1`.

  ## Adding a template

  Add a clause to `render/3` for each of `fr`, `ar` and the catch-all, then a
  row to `@inventory`. `Blastek.NotificationsTest` asserts every template in the
  inventory renders in every locale, so a half-translated addition fails the
  suite rather than silently reaching a customer in the wrong language.
  """

  @locales ~w(fr ar en)
  @default_locale "fr"

  # Every template that may be sent, and whether a person can turn it off.
  # `:transactional` messages are the direct consequence of something the
  # recipient just did; F0.10 is explicit that those always send.
  @inventory [
    {:login, :transactional},
    {:verify, :transactional},
    {:reset, :transactional},
    {:password_reset, :transactional},
    {:invitation, :transactional},
    {:venue_approved, :transactional},
    {:venue_rejected, :transactional},
    {:booking_confirmed_customer, :transactional},
    {:booking_confirmed_salon, :transactional},
    {:booking_requested_customer, :transactional},
    {:booking_requested_salon, :transactional},
    {:reminder_24h, :reminders},
    {:reminder_3h, :reminders},
    {:cancelled_by_customer, :transactional},
    {:cancelled_by_salon, :transactional},
    {:rescheduled, :transactional},
    # Asking for a review is not the consequence of anything the customer just
    # did — it is us wanting something from them. That makes it opt-outable,
    # under the same preference as reminders, and F0.10's rule that a person
    # who has said "no messages" gets none is what decides this, not F0.8's
    # wish for more reviews.
    {:review_invite, :reminders},
    {:review_reminder, :reminders},
    # The consequence of a moderation decision about their own words, and the
    # only notice they get that it happened.
    {:review_hidden, :transactional}
  ]

  def locales, do: @locales
  def default_locale, do: @default_locale
  def inventory, do: @inventory
  def names, do: Enum.map(@inventory, &elem(&1, 0))

  @doc """
  Which preference governs a template.

  `:transactional` means none: a confirmation for a booking somebody just made
  is not marketing, and suppressing it would leave them with no record of it.
  """
  def category(template) do
    case List.keyfind(@inventory, template, 0) do
      {_name, category} -> category
      nil -> :transactional
    end
  end

  def known?(template), do: List.keymember?(@inventory, template, 0)

  # Templates whose body *is* a credential: a one-time code, or a URL that acts
  # as one. The rendered text of these must not survive the send.
  @sensitive ~w(login verify reset password_reset invitation)a

  @doc """
  Whether a template's body would be usable by whoever reads it back.

  A login code is the entire credential for a phone-first account, and a
  password-reset link is a live one for an hour. The send log answers "did it
  go, did it arrive" and is readable by every platform admin, so for these the
  body is recorded as a marker rather than as text — see
  `Blastek.Notifications.send_now/3`. The provider still receives the real
  message; it is only the durable copy that is redacted.
  """
  def sensitive?(template), do: template in @sensitive

  def locale(requested) when requested in @locales, do: requested
  def locale(_), do: @default_locale

  @doc """
  Renders a template into a message body.

  Raises on an unknown template rather than returning a placeholder: a message
  with no body is worse than a crash, because the crash is visible.
  """
  def render(template, locale, assigns) do
    do_render(template, locale(locale), Map.new(assigns))
  end

  ## ---------- one-time codes and links ----------

  defp do_render(:login, "fr", %{code: code}),
    do: "Votre code Blastek : #{code}. Il expire dans 5 minutes."

  defp do_render(:login, "ar", %{code: code}),
    do: "رمز بلاستيك الخاص بك: #{isolate(code)}. ينتهي خلال 5 دقائق."

  defp do_render(:login, _en, %{code: code}),
    do: "Your Blastek code is #{code}. It expires in 5 minutes."

  defp do_render(:verify, "fr", %{code: code}),
    do: "Code de vérification Blastek : #{code}. Il expire dans 5 minutes."

  defp do_render(:verify, "ar", %{code: code}),
    do: "رمز التحقق من بلاستيك: #{isolate(code)}. ينتهي خلال 5 دقائق."

  defp do_render(:verify, _en, %{code: code}),
    do: "Your Blastek verification code is #{code}. It expires in 5 minutes."

  defp do_render(:reset, "fr", %{code: code}),
    do: "Code de réinitialisation Blastek : #{code}. Il expire dans 5 minutes."

  defp do_render(:reset, "ar", %{code: code}),
    do: "رمز إعادة تعيين كلمة المرور: #{isolate(code)}. ينتهي خلال 5 دقائق."

  defp do_render(:reset, _en, %{code: code}),
    do: "Your Blastek password reset code is #{code}. It expires in 5 minutes."

  defp do_render(:password_reset, "fr", %{url: url}),
    do: "Réinitialisez votre mot de passe Blastek : #{url} (valable 1 heure)."

  defp do_render(:password_reset, "ar", %{url: url}),
    do: "أعد تعيين كلمة مرور بلاستيك: #{isolate(url)} (صالح لمدة ساعة)."

  defp do_render(:password_reset, _en, %{url: url}),
    do: "Reset your Blastek password: #{url} (valid for 1 hour)."

  defp do_render(:invitation, "fr", %{venue: venue, role: role, url: url}),
    do: "#{venue} vous invite à rejoindre son équipe sur Blastek (#{role}) : #{url}"

  defp do_render(:invitation, "ar", %{venue: venue, role: role, url: url}),
    do:
      "#{isolate(venue)} يدعوك للانضمام إلى الفريق على بلاستيك (#{isolate(role)}): #{isolate(url)}"

  defp do_render(:invitation, _en, %{venue: venue, role: role, url: url}),
    do: "#{venue} invited you to join their team on Blastek as #{role}: #{url}"

  ## ---------- venue review ----------

  defp do_render(:venue_approved, "fr", %{venue: venue}),
    do: "#{venue} est en ligne sur Blastek. Vos clients peuvent réserver dès maintenant."

  defp do_render(:venue_approved, "ar", %{venue: venue}),
    do: "#{isolate(venue)} أصبح متاحًا على بلاستيك. يمكن لعملائك الحجز الآن."

  defp do_render(:venue_approved, _en, %{venue: venue}),
    do: "#{venue} is live on Blastek. Your customers can book now."

  defp do_render(:venue_rejected, "fr", %{venue: venue, reason: reason}),
    do: "#{venue} n'a pas encore été validé : #{reason} Corrigez et renvoyez."

  defp do_render(:venue_rejected, "ar", %{venue: venue, reason: reason}),
    do: "#{isolate(venue)} لم تتم الموافقة عليه بعد: #{reason} صحّح وأعد الإرسال."

  defp do_render(:venue_rejected, _en, %{venue: venue, reason: reason}),
    do: "#{venue} was not approved yet: #{reason} Fix it and resubmit."

  ## ---------- bookings ----------
  #
  # `when` is a pre-formatted, already-localized date and time — see
  # `Blastek.Notifications.Format`. Templates never do calendar arithmetic.

  defp do_render(:booking_confirmed_customer, "fr", a),
    do:
      "Réservation confirmée chez #{a.venue} : #{a.service} le #{a.when} avec #{a.staff}." <>
        " Réf #{a.ref}." <> links_fr(a)

  defp do_render(:booking_confirmed_customer, "ar", a),
    do:
      "تم تأكيد حجزك في #{isolate(a.venue)}: #{isolate(a.service)} يوم #{isolate(a.when)} مع #{isolate(a.staff)}." <>
        " المرجع #{isolate(a.ref)}." <> links_ar(a)

  defp do_render(:booking_confirmed_customer, _en, a),
    do:
      "Booking confirmed at #{a.venue}: #{a.service} on #{a.when} with #{a.staff}." <>
        " Ref #{a.ref}." <> links_en(a)

  defp do_render(:booking_requested_customer, "fr", a),
    do:
      "Demande reçue chez #{a.venue} : #{a.service} le #{a.when}." <>
        " Le salon confirme sous peu. Réf #{a.ref}."

  defp do_render(:booking_requested_customer, "ar", a),
    do:
      "تم استلام طلبك في #{isolate(a.venue)}: #{isolate(a.service)} يوم #{isolate(a.when)}." <>
        " سيؤكد الصالون قريبًا. المرجع #{isolate(a.ref)}."

  defp do_render(:booking_requested_customer, _en, a),
    do:
      "Request received at #{a.venue}: #{a.service} on #{a.when}." <>
        " The salon will confirm shortly. Ref #{a.ref}."

  defp do_render(:booking_confirmed_salon, "fr", a),
    do: "Nouvelle réservation en ligne : #{a.client}, #{a.service} le #{a.when} (#{a.staff})."

  defp do_render(:booking_confirmed_salon, "ar", a),
    do:
      "حجز جديد عبر الإنترنت: #{isolate(a.client)}، #{isolate(a.service)} يوم #{isolate(a.when)} (#{isolate(a.staff)})."

  defp do_render(:booking_confirmed_salon, _en, a),
    do: "New online booking: #{a.client}, #{a.service} on #{a.when} (#{a.staff})."

  defp do_render(:booking_requested_salon, "fr", a),
    do: "Demande à confirmer : #{a.client}, #{a.service} le #{a.when} (#{a.staff})."

  defp do_render(:booking_requested_salon, "ar", a),
    do:
      "طلب بانتظار التأكيد: #{isolate(a.client)}، #{isolate(a.service)} يوم #{isolate(a.when)} (#{isolate(a.staff)})."

  defp do_render(:booking_requested_salon, _en, a),
    do: "Booking request to confirm: #{a.client}, #{a.service} on #{a.when} (#{a.staff})."

  ## ---------- reminders ----------

  defp do_render(:reminder_24h, "fr", a),
    do: "Rappel : #{a.service} chez #{a.venue} demain #{a.when} avec #{a.staff}." <> links_fr(a)

  defp do_render(:reminder_24h, "ar", a),
    do:
      "تذكير: #{isolate(a.service)} في #{isolate(a.venue)} غدًا #{isolate(a.when)} مع #{isolate(a.staff)}." <>
        links_ar(a)

  defp do_render(:reminder_24h, _en, a),
    do: "Reminder: #{a.service} at #{a.venue} tomorrow #{a.when} with #{a.staff}." <> links_en(a)

  defp do_render(:reminder_3h, "fr", a),
    do: "À tout à l'heure : #{a.service} chez #{a.venue} à #{a.time}." <> links_fr(a)

  defp do_render(:reminder_3h, "ar", a),
    do:
      "نراك قريبًا: #{isolate(a.service)} في #{isolate(a.venue)} على #{isolate(a.time)}." <>
        links_ar(a)

  defp do_render(:reminder_3h, _en, a),
    do: "See you soon: #{a.service} at #{a.venue} at #{a.time}." <> links_en(a)

  ## ---------- cancellation and reschedule ----------

  defp do_render(:cancelled_by_customer, "fr", a),
    do: "Annulation : #{a.client} a annulé #{a.service} du #{a.when}. Le créneau est libre."

  defp do_render(:cancelled_by_customer, "ar", a),
    do:
      "إلغاء: #{isolate(a.client)} ألغى #{isolate(a.service)} ليوم #{isolate(a.when)}. الموعد متاح الآن."

  defp do_render(:cancelled_by_customer, _en, a),
    do: "Cancellation: #{a.client} cancelled #{a.service} on #{a.when}. The slot is free."

  defp do_render(:cancelled_by_salon, "fr", a),
    do:
      "#{a.venue} a dû annuler votre rendez-vous du #{a.when}." <>
        " Appelez le salon pour replanifier#{phone_fr(a)}."

  defp do_render(:cancelled_by_salon, "ar", a),
    do:
      "#{isolate(a.venue)} اضطر لإلغاء موعدك يوم #{isolate(a.when)}." <>
        " اتصل بالصالون لإعادة الحجز#{phone_ar(a)}."

  defp do_render(:cancelled_by_salon, _en, a),
    do:
      "#{a.venue} had to cancel your appointment on #{a.when}." <>
        " Call the salon to rebook#{phone_en(a)}."

  defp do_render(:rescheduled, "fr", a),
    do: "Votre rendez-vous chez #{a.venue} est déplacé au #{a.when} avec #{a.staff}."

  defp do_render(:rescheduled, "ar", a),
    do: "تم نقل موعدك في #{isolate(a.venue)} إلى #{isolate(a.when)} مع #{isolate(a.staff)}."

  defp do_render(:rescheduled, _en, a),
    do: "Your appointment at #{a.venue} has moved to #{a.when} with #{a.staff}."

  ## ---------- reviews ----------
  #
  # One question and one link. A message that asks for a rating, explains the
  # scale and offers three options gets read as an advertisement; this gets read
  # as a question, which is the only version that gets answered.

  defp do_render(:review_invite, "fr", a),
    do: "Merci de votre visite chez #{a.venue} ! Comment ça s'est passé ? #{a.review_url}"

  defp do_render(:review_invite, "ar", a),
    do: "شكرًا لزيارتك #{isolate(a.venue)}! كيف كانت التجربة؟ #{isolate(a.review_url)}"

  defp do_render(:review_invite, _en, a),
    do: "Thanks for visiting #{a.venue}! How did it go? #{a.review_url}"

  defp do_render(:review_reminder, "fr", a),
    do: "Un avis sur #{a.venue} ? Une minute suffit : #{a.review_url}"

  defp do_render(:review_reminder, "ar", a),
    do: "رأيك في #{isolate(a.venue)}؟ دقيقة واحدة تكفي: #{isolate(a.review_url)}"

  defp do_render(:review_reminder, _en, a),
    do: "A quick word about #{a.venue}? One minute: #{a.review_url}"

  # The reason is a category, never the moderator's note — see
  # `Blastek.Salon.Reviews.reason_label/2`.
  defp do_render(:review_hidden, "fr", a),
    do: "Votre avis a été retiré : #{a.reason}. Vous pouvez nous écrire si c'est une erreur."

  defp do_render(:review_hidden, "ar", a),
    do: "تمت إزالة تقييمك: #{isolate(a.reason)}. راسلنا إذا كان ذلك خطأً."

  defp do_render(:review_hidden, _en, a),
    do: "Your review was removed: #{a.reason}. Write to us if that is a mistake."

  ## ---------- fragments ----------

  # One-tap links are optional: a message sent before the token exists, or to a
  # channel where a URL is noise, simply omits them.
  defp links_fr(%{cancel_url: url}) when is_binary(url), do: " Annuler : #{url}"
  defp links_fr(_), do: ""

  defp links_ar(%{cancel_url: url}) when is_binary(url), do: " للإلغاء: #{isolate(url)}"
  defp links_ar(_), do: ""

  defp links_en(%{cancel_url: url}) when is_binary(url), do: " Cancel: #{url}"
  defp links_en(_), do: ""

  defp phone_fr(%{phone: phone}) when is_binary(phone) and phone != "", do: " : #{phone}"
  defp phone_fr(_), do: ""

  defp phone_ar(%{phone: phone}) when is_binary(phone) and phone != "", do: ": #{isolate(phone)}"
  defp phone_ar(_), do: ""

  defp phone_en(%{phone: phone}) when is_binary(phone) and phone != "", do: ": #{phone}"
  defp phone_en(_), do: ""

  @doc """
  Wraps a value so it keeps its own direction inside a right-to-left sentence.

  Without it, "Le Salon Anfa" embedded in Arabic can render with its words
  reordered, and "14:30" can come out as "30:14" — the bidirectional algorithm
  resolves the neutral characters against the surrounding text, not against the
  value's own.
  """
  # Escaped rather than literal: Elixir refuses bidirectional control characters
  # in source, because invisibly reordering code is how Trojan Source works.
  @isolate_start "\u2066"
  @isolate_end "\u2069"

  def isolate(value), do: @isolate_start <> to_string(value) <> @isolate_end
end
