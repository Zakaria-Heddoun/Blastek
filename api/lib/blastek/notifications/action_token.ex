defmodule Blastek.Notifications.ActionToken do
  @moduledoc """
  One-tap links for confirm and cancel (E6-T8 / F0.10).

  A reminder arriving on WhatsApp is read on a phone, at a bus stop, by somebody
  who is not signed in and will not sign in to cancel. F0.10 asks for links that
  act without a login, which means the link *is* the credential — so it has to
  be narrow in every direction that matters:

    * **One appointment, one action.** The payload names both. A cancel link
      cannot be replayed as a confirm, and neither reaches a second booking.
    * **It expires.** Fourteen days, comfortably past the appointment it
      concerns and well short of forever.
    * **It is signed, not stored.** `Phoenix.Token` carries the payload in the
      token itself; there is no table to leak and nothing to clean up. The
      signing secret is the endpoint's, so rotating it invalidates every
      outstanding link at once — which is the correct behaviour if it leaks.

  Not stored also means **not revocable individually**, which is the trade. It
  is acceptable here because the actions are: cancelling an appointment you were
  told about, or confirming one. Neither moves money, and the appointment's own
  state is the backstop — a cancelled booking cannot be cancelled twice.
  """

  @salt "notification action"
  @max_age 60 * 60 * 24 * 14

  @actions ~w(confirm cancel review)a

  def actions, do: @actions

  @doc "A token authorizing one action on one appointment."
  def sign(appointment_id, action) when action in @actions do
    Phoenix.Token.sign(BlastekWeb.Endpoint, @salt, %{
      appointment_id: appointment_id,
      action: action
    })
  end

  @doc """
  Verifies a token, returning `{:ok, appointment_id, action}`.

  Errors are deliberately indistinguishable to the caller — expired and forged
  both mean "this link does not work", and telling them apart only helps
  somebody probing.
  """
  def verify(token) when is_binary(token) do
    case Phoenix.Token.verify(BlastekWeb.Endpoint, @salt, token, max_age: @max_age) do
      {:ok, %{appointment_id: id, action: action}} when action in @actions ->
        {:ok, id, action}

      _ ->
        {:error, :invalid}
    end
  end

  def verify(_), do: {:error, :invalid}

  @doc """
  The full URL a message should carry.

  Built from the configured public web base so the link works from a phone,
  which is the whole point — see `Blastek.Storage.S3` for the same lesson learnt
  the hard way with presigned URLs.
  """
  def url(appointment_id, action) do
    base =
      Application.get_env(:blastek, :public_web_url, "http://localhost:5173")
      |> String.trim_trailing("/")

    "#{base}/a/#{action}/#{sign(appointment_id, action)}"
  end

  @doc """
  The link a review invite carries (E10-T3 / F0.8).

  Its own path because it is its own kind of thing: `/a/:action/:token` is a
  one-tap link that acts and reports back, while this opens a page with a form
  on it. Nothing is written until the customer submits a rating, so unlike its
  siblings this URL is a plain GET that changes nothing — a link preview
  fetching it costs a page render.

  The token still authorizes exactly one review of one booking; the mutation
  behind the form is what checks it.
  """
  def review_url(appointment_id) do
    base =
      Application.get_env(:blastek, :public_web_url, "http://localhost:5173")
      |> String.trim_trailing("/")

    "#{base}/review/#{sign(appointment_id, :review)}"
  end
end
