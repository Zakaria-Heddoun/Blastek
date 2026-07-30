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

# Elixir ships a UTC-only timezone database, under which every conversion to
# Africa/Casablanca raises. Reminders are scheduled in local wall-clock time
# ("the evening before"), so that raise is the difference between a reminder at
# 20:00 and one at 21:00 — and during Ramadan, when Morocco moves to UTC+0, two
# hours.
config :elixir, :time_zone_database, Tz.TimeZoneDatabase

# Background jobs (E6-T1 / F0.10).
#
# Two queues rather than one. `notifications` carries work a person is waiting
# on — a confirmation the customer expects within seconds — and `scheduled`
# carries reminders, which are enqueued at booking time and sit for a day. A
# morning's worth of reminders coming due at once must not delay the
# confirmation of a booking made in that same minute.
#
# `Pruner` keeps the table from growing without bound; the send log in
# `notifications` is the durable record, not `oban_jobs`.
config :blastek, Oban,
  repo: Blastek.Repo,
  queues: [notifications: 10, scheduled: 5],
  plugins: [
    {Oban.Plugins.Pruner, max_age: 60 * 60 * 24 * 7},
    # Jobs whose node died mid-run are otherwise stuck `executing` forever.
    {Oban.Plugins.Lifeline, rescue_after: :timer.minutes(30)}
  ]

# Message delivery. `DevLogger` prints instead of sending; `runtime.exs`
# switches to the real chain when credentials are present. See
# `Blastek.Notifications.Provider`.
config :blastek, :notifications_provider, Blastek.Notifications.DevLogger

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
