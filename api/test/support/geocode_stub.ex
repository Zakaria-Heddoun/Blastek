defmodule Blastek.Geocode.Stub do
  @moduledoc """
  Test geocoder. Lives in `test/support` so no test double ships to production.

  Per-process rather than global state: the suite is `async: true`, so a canned
  response stored in the process dictionary cannot leak into a test running
  concurrently in another process.

  Default behaviour with nothing staged is `{:error, :not_found}` — the common
  real outcome, and it keeps a test that forgot to stage a response honest
  instead of silently succeeding.
  """
  @behaviour Blastek.Geocode

  @key :geocode_stub_response

  @doc "Stages the next result. `:not_found` and `:boom` stage failures."
  def stub(:not_found), do: Process.put(@key, {:error, :not_found})
  def stub(:boom), do: Process.put(@key, {:error, :timeout})

  def stub(%{} = result) do
    Process.put(@key, {:ok, Map.put_new(result, :label, "Stubbed address")})
  end

  def stub(lat, lng, label \\ "Stubbed address") do
    stub(%{lat: lat, lng: lng, label: label})
  end

  @doc "The query the code under test actually sent, or nil."
  def last_query, do: Process.get(:geocode_stub_query)

  @impl true
  def geocode(query) do
    Process.put(:geocode_stub_query, query)
    Process.get(@key, {:error, :not_found})
  end
end
