defmodule Blastek.Accounts.Phone do
  @moduledoc """
  Moroccan phone numbers, normalized to E.164 (E3-T4 / F0.2).

  Once a phone number is an identity, "the same number" has to mean one string.
  People write theirs as `0612-34-56-78`, `+212 6 12 34 56 78`, `212612345678`
  or `00212612345678`, and all four are the same person. Storing them as typed
  would let one human hold four accounts and would make "is this number already
  verified?" unanswerable.

  Everything therefore funnels through `normalize/1`, which is **total**: it
  either returns the one canonical form or refuses. It never returns a
  best-effort guess, because a wrong guess sends someone else's OTP to a
  stranger.

  ## What counts as valid

  Moroccan subscriber numbers are nine digits after the `+212` country code, and
  the leading digit says what kind of line it is:

    * `6`, `7` — mobile. The only kind that can receive an OTP.
    * `5` — landline. Accepted as a contact number, rejected for OTP.

  National notation writes those with a leading `0` (`06…`), which the country
  code replaces rather than joins — `+2120612…` is a common and invalid mangling
  that this module accepts as input and repairs.
  """

  @country_code "212"
  @mobile_prefixes ~w(6 7)
  @landline_prefixes ~w(5)

  @type reason :: :empty | :not_a_number | :wrong_length | :unsupported_country | :not_mobile

  @doc """
  Canonicalizes any accepted spelling to `+212XXXXXXXXX`.

      iex> Blastek.Accounts.Phone.normalize("0612-34-56-78")
      {:ok, "+212612345678"}

  Idempotent: normalizing an already-normalized number returns it unchanged.
  """
  @spec normalize(String.t() | nil) :: {:ok, String.t()} | {:error, reason}
  def normalize(nil), do: {:error, :empty}

  def normalize(input) when is_binary(input) do
    digits = strip(input)

    cond do
      digits == "" ->
        {:error, :empty}

      # Reject before parsing rather than after: "abc" and "" are different
      # mistakes and deserve different messages.
      not String.match?(digits, ~r/^\d+$/) ->
        {:error, :not_a_number}

      true ->
        digits |> to_national() |> build()
    end
  end

  def normalize(_), do: {:error, :not_a_number}

  @doc """
  Like `normalize/1`, but also insists the number can receive a text message.

  A landline is a perfectly good contact number and a useless OTP destination,
  and finding that out at delivery time means a user staring at a code that will
  never arrive.
  """
  @spec normalize_mobile(String.t() | nil) :: {:ok, String.t()} | {:error, reason}
  def normalize_mobile(input) do
    with {:ok, normalized} <- normalize(input) do
      if mobile?(normalized), do: {:ok, normalized}, else: {:error, :not_mobile}
    end
  end

  @doc "Whether an already-normalized number is a mobile line."
  def mobile?(<<"+", @country_code, first::binary-size(1), _rest::binary>>),
    do: first in @mobile_prefixes

  def mobile?(_), do: false

  @doc """
  Formats for display in the local convention: `06 12 34 56 78`.

  Storage stays E.164; this is only ever for human eyes.
  """
  def format_local(<<"+", @country_code, subscriber::binary-size(9)>>) do
    format_pairs("0" <> subscriber)
  end

  def format_local(other), do: other

  @doc "Hides the middle of a number for confirmation screens: `06 •• •• 56 78`."
  def mask(<<"+", @country_code, subscriber::binary-size(9)>>) do
    keep_last = String.slice(subscriber, 5, 4)
    "0" <> String.slice(subscriber, 0, 1) <> " •• •• " <> format_pairs(keep_last)
  end

  def mask(other), do: other

  @doc "Human-readable reason, safe to show a user."
  def message(:empty), do: "Enter your phone number."
  def message(:not_a_number), do: "That does not look like a phone number."
  def message(:wrong_length), do: "A Moroccan number has 9 digits after the 0."
  def message(:unsupported_country), do: "Only Moroccan numbers (+212) are supported for now."
  def message(:not_mobile), do: "Enter a mobile number — we cannot text a landline."
  def message(_), do: "That phone number is not valid."

  ## ---------- internals ----------

  # Everything a human might use as a separator, plus the international prefixes.
  defp strip(input) do
    input
    |> String.trim()
    |> String.replace(~r/^\+/, "")
    |> String.replace(~r/^00/, "")
    |> String.replace(~r/[\s\-\.\(\)\/]/u, "")
  end

  # Reduces any accepted spelling to the bare 9-digit subscriber number.
  defp to_national(digits) do
    cond do
      # "2120612345678" — country code followed by the national trunk 0, which
      # is a common mangling rather than a distinct number.
      String.starts_with?(digits, @country_code <> "0") ->
        String.replace_prefix(digits, @country_code <> "0", "")

      String.starts_with?(digits, @country_code) ->
        String.replace_prefix(digits, @country_code, "")

      String.starts_with?(digits, "0") ->
        String.replace_prefix(digits, "0", "")

      true ->
        digits
    end
  end

  defp build(subscriber) do
    cond do
      String.length(subscriber) != 9 ->
        # A plausible-looking number for another country is a clearer error than
        # "wrong length", which would be baffling for a French mobile.
        if String.length(subscriber) > 9,
          do: {:error, :unsupported_country},
          else: {:error, :wrong_length}

      String.first(subscriber) not in (@mobile_prefixes ++ @landline_prefixes) ->
        {:error, :unsupported_country}

      true ->
        {:ok, "+" <> @country_code <> subscriber}
    end
  end

  defp format_pairs(digits) do
    digits |> String.graphemes() |> Enum.chunk_every(2) |> Enum.map_join(" ", &Enum.join/1)
  end
end
