defmodule Blastek.Notifications do
  @moduledoc """
  Outbound messages to customers (E3-T8 / F0.2, standing in for F0.10).

  **Deliberately minimal.** E6 builds the real `Notifications` context —
  templates in the database, per-user preferences, a send log, WhatsApp with SMS
  fallback, and Oban to retry. Auth needs exactly one thing from all of that: a
  way to get six digits onto a phone. So this is the seam and nothing more.

  What it does establish, because these are the parts that would be painful to
  retrofit:

    * a provider **behaviour**, so swapping the dev logger for WhatsApp is a
      config change rather than a rewrite of every call site;
    * **locale-aware templates**, because the copy is French and Arabic from day
      one and English is the fallback, not the default;
    * a return value callers must handle — delivery fails, and an OTP flow that
      assumes success leaves a user waiting for a code that never comes.

  Never log or return the code itself except through `DevLogger`, which exists
  precisely so nobody is tempted to leak it into an API response.
  """
  @type message :: %{
          to: String.t(),
          channel: :sms | :whatsapp,
          body: String.t(),
          template: atom,
          locale: String.t()
        }

  @callback deliver(message) :: :ok | {:error, term}

  @default_locale "fr"
  @locales ~w(fr ar en)

  def provider,
    do: Application.get_env(:blastek, :notifications_provider, Blastek.Notifications.DevLogger)

  @doc """
  Sends a one-time code.

  `purpose` only changes the wording — the code itself is issued and checked by
  `Blastek.Accounts.Otp`.
  """
  @spec deliver_otp(String.t(), String.t(), atom, keyword) :: :ok | {:error, term}
  def deliver_otp(phone, code, purpose, opts \\ []) do
    locale = locale(opts[:locale])

    deliver(%{
      to: phone,
      # WhatsApp first with SMS fallback is F0.10's job; until then everything
      # is nominally SMS.
      channel: :sms,
      body: render(purpose, locale, code: code),
      template: purpose,
      locale: locale
    })
  end

  @doc "Sends a password-reset link (the email variant of the reset flow)."
  @spec deliver_password_reset(String.t(), String.t(), keyword) :: :ok | {:error, term}
  def deliver_password_reset(email, url, opts \\ []) do
    locale = locale(opts[:locale])

    deliver(%{
      to: email,
      channel: :sms,
      body: render(:password_reset, locale, url: url),
      template: :password_reset,
      locale: locale
    })
  end

  @doc "Sends a venue invitation link (E4-T1)."
  @spec deliver_invitation(String.t(), String.t(), String.t(), String.t(), keyword) ::
          :ok | {:error, term}
  def deliver_invitation(to, venue_name, role, url, opts \\ []) do
    locale = locale(opts[:locale])

    deliver(%{
      to: to,
      channel: :sms,
      body:
        render(:invitation, locale, venue: venue_name, role: role_name(role, locale), url: url),
      template: :invitation,
      locale: locale
    })
  end

  @doc "Tells an owner whether their venue was approved (E5-T8)."
  @spec deliver_venue_decision(String.t(), String.t(), :approved | :rejected, String.t(), keyword) ::
          :ok | {:error, term}
  def deliver_venue_decision(to, venue_name, decision, reason, opts \\ []) do
    locale = locale(opts[:locale])

    deliver(%{
      to: to,
      channel: :sms,
      body: render(decision_template(decision), locale, venue: venue_name, reason: reason),
      template: decision_template(decision),
      locale: locale
    })
  end

  defp decision_template(:approved), do: :venue_approved
  defp decision_template(_), do: :venue_rejected

  defp deliver(message), do: provider().deliver(message)

  defp locale(requested) when requested in @locales, do: requested
  defp locale(_), do: @default_locale

  ## ---------- templates ----------
  #
  # Inline for now. F0.10 moves these into the database so a venue can edit its
  # own copy and Meta can approve the WhatsApp variants; the shape stays.

  defp render(:login, "fr", code: code),
    do: "Votre code Blastek : #{code}. Il expire dans 5 minutes."

  defp render(:login, "ar", code: code),
    do: "رمز بلاستيك الخاص بك: #{code}. ينتهي خلال 5 دقائق."

  defp render(:login, _en, code: code),
    do: "Your Blastek code is #{code}. It expires in 5 minutes."

  defp render(:verify, "fr", code: code),
    do: "Code de vérification Blastek : #{code}. Il expire dans 5 minutes."

  defp render(:verify, "ar", code: code),
    do: "رمز التحقق من بلاستيك: #{code}. ينتهي خلال 5 دقائق."

  defp render(:verify, _en, code: code),
    do: "Your Blastek verification code is #{code}. It expires in 5 minutes."

  defp render(:reset, "fr", code: code),
    do: "Code de réinitialisation Blastek : #{code}. Il expire dans 5 minutes."

  defp render(:reset, "ar", code: code),
    do: "رمز إعادة تعيين كلمة المرور: #{code}. ينتهي خلال 5 دقائق."

  defp render(:reset, _en, code: code),
    do: "Your Blastek password reset code is #{code}. It expires in 5 minutes."

  defp render(:password_reset, "fr", url: url),
    do: "Réinitialisez votre mot de passe Blastek : #{url} (valable 1 heure)."

  defp render(:password_reset, "ar", url: url),
    do: "أعد تعيين كلمة مرور بلاستيك: #{url} (صالح لمدة ساعة)."

  defp render(:password_reset, _en, url: url),
    do: "Reset your Blastek password: #{url} (valid for 1 hour)."

  defp render(:invitation, "fr", venue: venue, role: role, url: url),
    do: "#{venue} vous invite à rejoindre son équipe sur Blastek (#{role}) : #{url}"

  defp render(:invitation, "ar", venue: venue, role: role, url: url),
    do: "#{venue} يدعوك للانضمام إلى الفريق على بلاستيك (#{role}): #{url}"

  defp render(:invitation, _en, venue: venue, role: role, url: url),
    do: "#{venue} invited you to join their team on Blastek as #{role}: #{url}"

  defp render(:venue_approved, "fr", venue: venue, reason: _),
    do: "#{venue} est en ligne sur Blastek. Vos clients peuvent réserver dès maintenant."

  defp render(:venue_approved, "ar", venue: venue, reason: _),
    do: "#{venue} أصبح متاحًا على بلاستيك. يمكن لعملائك الحجز الآن."

  defp render(:venue_approved, _en, venue: venue, reason: _),
    do: "#{venue} is live on Blastek. Your customers can book now."

  defp render(:venue_rejected, "fr", venue: venue, reason: reason),
    do: "#{venue} n'a pas encore été validé : #{reason} Corrigez et renvoyez."

  defp render(:venue_rejected, "ar", venue: venue, reason: reason),
    do: "#{venue} لم تتم الموافقة عليه بعد: #{reason} صحّح وأعد الإرسال."

  defp render(:venue_rejected, _en, venue: venue, reason: reason),
    do: "#{venue} was not approved yet: #{reason} Fix it and resubmit."

  # Roles are stored in English; the invitation is read by the invitee.
  defp role_name(role, "fr") do
    %{
      "owner" => "propriétaire",
      "manager" => "responsable",
      "receptionist" => "réception",
      "staff" => "praticien"
    }[role] || role
  end

  defp role_name(role, "ar") do
    %{"owner" => "مالك", "manager" => "مدير", "receptionist" => "استقبال", "staff" => "موظف"}[
      role
    ] ||
      role
  end

  defp role_name(role, _en), do: role
end

defmodule Blastek.Notifications.DevLogger do
  @moduledoc """
  Prints messages to the log instead of sending them.

  The default everywhere except production. It logs the **full body, including
  the code** — that is the entire point in development, and it is why this
  provider must never be the configured one in production.
  """
  @behaviour Blastek.Notifications

  require Logger

  @impl true
  def deliver(%{to: to, body: body, channel: channel}) do
    Logger.info("""

    ┌─ #{String.upcase(to_string(channel))} → #{to}
    │  #{body}
    └─ (Blastek.Notifications.DevLogger — not actually sent)
    """)

    :ok
  end
end
