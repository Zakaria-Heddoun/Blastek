defmodule Blastek.Geocode do
  @moduledoc """
  Turns a venue's street address into coordinates (E8-T4 / F0.6).

  Behind a behaviour for two reasons: tests must never touch the network, and
  the provider is a decision we may revisit (Nominatim's terms forbid heavy
  automated use, so a paid provider is likely at scale).

  Geocoding is **advisory**. It is allowed to fail, return nothing, or land in
  the wrong street, so nothing in booking or search depends on coordinates
  existing — a venue with no pin is listed, just not distance-sorted. When the
  guess is wrong the owner drags the marker, and the manual pin always wins;
  see `Blastek.Venues.set_location/3`.
  """

  @type result :: %{lat: float, lng: float, label: String.t()}

  @callback geocode(query :: String.t()) :: {:ok, result} | {:error, term}

  def adapter, do: Application.get_env(:blastek, :geocoder, Blastek.Geocode.Nominatim)

  @doc """
  Geocodes a free-form address, biased to Morocco.

  Returns `{:error, :not_found}` when the provider has no match — an ordinary
  outcome for a new salon on a street the map does not know, not an exception.
  """
  @spec geocode(String.t()) :: {:ok, result} | {:error, term}
  def geocode(query) when is_binary(query) do
    case String.trim(query) do
      "" -> {:error, :empty}
      trimmed -> adapter().geocode(trimmed)
    end
  end

  def geocode(_), do: {:error, :empty}

  @doc "Builds the query string a venue's fields imply."
  def query_for(%{address: address, city: city}) do
    [address, city, "Morocco"]
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
    |> Enum.uniq()
    |> Enum.join(", ")
  end
end
