import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
# Host and port mirror dev: inside Docker the database is `db:5432`; from the
# host it is the mapped 5433.
config :blastek, Blastek.Repo,
  username: "postgres",
  password: "postgres",
  hostname: System.get_env("DB_HOST", "localhost"),
  port:
    String.to_integer(
      System.get_env("DB_PORT", if(System.get_env("DB_HOST"), do: "5432", else: "5433"))
    ),
  database: "blastek_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :blastek, BlastekWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "UoTy92Hn7Eh1a2gUsfBxWyl5KacFNC8V3NAO1XYqlPht1WsNEnRvLfHl4s+55DOT",
  server: false

# Media lands in a scratch directory rather than priv/uploads, so a test run
# leaves no files behind in the repository.
config :blastek, Blastek.Storage.Local,
  root: Path.join(System.tmp_dir!(), "blastek-test-uploads"),
  base_url: "http://localhost:4002"

# Geocoding must never reach the network from a test: it would be slow, flaky,
# and rude to a free public service. The stub is driven per-test.
config :blastek, :geocoder, Blastek.Geocode.Stub

# Notifications are collected in-process so a test can read the code it was
# "sent" — the same way a user reads their text message.
config :blastek, :notifications_provider, Blastek.Notifications.Collector

# Password and OTP hashing is deliberately slow in production — that slowness is
# the security property. In tests it is pure cost, and the suite hashes on
# nearly every fixture, so the work factor drops to its minimum here.
config :pbkdf2_elixir, :rounds, 1

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime
