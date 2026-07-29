defmodule Blastek.Geocode.Nominatim do
  @moduledoc """
  OpenStreetMap's public geocoder.

  Free, no key, and bound by a usage policy this module honours deliberately:

    * a **real identifying User-Agent** — Nominatim blocks anonymous clients,
      and rightly so
    * results biased to Morocco (`countrycodes=ma`), because "Agdal" is a
      district in Rabat and also a lake in Tibet
    * one result requested, since a venue has one address

  Not called on a request path anyone waits on: onboarding geocodes once, and a
  failure leaves the venue pinless rather than blocking it.
  """
  @behaviour Blastek.Geocode

  require Logger

  alias Blastek.HTTP

  @endpoint "https://nominatim.openstreetmap.org/search"

  # Nominatim's policy requires a contactable identifier, not a browser string.
  @user_agent "Blastek/0.1 (salon booking; +https://blastek.ma)"

  @impl true
  def geocode(query) do
    url =
      @endpoint <>
        "?" <>
        URI.encode_query(%{
          "q" => query,
          "format" => "jsonv2",
          "limit" => "1",
          "countrycodes" => "ma",
          "addressdetails" => "0"
        })

    case HTTP.request(:get, url, [{"user-agent", @user_agent}, {"accept", "application/json"}]) do
      {:ok, %{body: body}} -> parse(body)
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse(body) do
    case Jason.decode(body) do
      {:ok, [%{"lat" => lat, "lon" => lon} = first | _]} ->
        with {latitude, _} <- Float.parse(lat),
             {longitude, _} <- Float.parse(lon) do
          {:ok,
           %{
             lat: latitude,
             lng: longitude,
             label: Map.get(first, "display_name", "")
           }}
        else
          # A non-numeric lat/lon means the response shape changed under us.
          _ -> {:error, :unparsable}
        end

      {:ok, []} ->
        {:error, :not_found}

      {:ok, _other} ->
        {:error, :unparsable}

      {:error, reason} ->
        Logger.warning("nominatim returned undecodable JSON: #{inspect(reason)}")
        {:error, :unparsable}
    end
  end
end
