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
  require Logger

  alias Blastek.Accounts.Phone

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

  @doc false
  def masked(to) do
    if String.contains?(to, "@"), do: mask_email(to), else: Phone.mask(to)
  end

  defp mask_email(email) do
    case String.split(email, "@") do
      [name, domain] -> String.slice(name, 0, 2) <> "•••@" <> domain
      _ -> "•••"
    end
  end
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
