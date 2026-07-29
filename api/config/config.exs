# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :blastek,
  ecto_repos: [Blastek.Repo],
  generators: [timestamp_type: :utc_datetime]

# Configures the endpoint
config :blastek, BlastekWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [json: BlastekWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Blastek.PubSub,
  live_view: [signing_salt: "g51HUU8c"]

# Configures Elixir's Logger
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Media storage. The filesystem adapter is the default so a bare checkout (and
# CI) works with no object store; `config/runtime.exs` switches to S3 when
# S3_BUCKET is present. See `Blastek.Storage`.
config :blastek, :storage_adapter, Blastek.Storage.Local

# Address geocoding. Nominatim is OpenStreetMap's public service — free, and
# rate-limited to roughly one request a second, which is ample for onboarding.
config :blastek, :geocoder, Blastek.Geocode.Nominatim

# ExAws is used for request signing only; `Blastek.Storage.S3` performs the
# transfers itself, so no ExAws HTTP client is configured.
config :ex_aws, json_codec: Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
