defmodule Blastek.MixProject do
  use Mix.Project

  def project do
    [
      app: :blastek,
      version: "0.1.0",
      elixir: "~> 1.14",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps()
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {Blastek.Application, []},
      # :inets/:ssl back the geocoder's HTTP client (`:httpc`) — a dependency-free
      # client is proportionate for a few hundred geocode calls a day.
      extra_applications: [:logger, :runtime_tools, :inets, :ssl]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:phoenix, "~> 1.7.14"},
      {:phoenix_ecto, "~> 4.5"},
      {:ecto_sql, "~> 3.10"},
      {:postgrex, ">= 0.0.0"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:jason, "~> 1.2"},
      {:dns_cluster, "~> 0.1.1"},
      {:bandit, "~> 1.5"},
      {:absinthe, "~> 1.7"},
      {:absinthe_plug, "~> 1.5"},
      {:absinthe_phoenix, "~> 2.0"},
      {:cors_plug, "~> 3.0"},
      {:pbkdf2_elixir, "~> 2.2"},
      # Background jobs, on Postgres rather than a second datastore. Notification
      # delivery must survive a provider outage, and a reminder scheduled for
      # 20:00 tomorrow has to survive a deploy at 19:00 — both are `oban_jobs`
      # rows in the database we already run.
      {:oban, "~> 2.18"},
      # A real timezone database. Elixir ships with a UTC-only one, under which
      # every "24 hours before, local time" reminder silently lands an hour
      # late — and two hours off during Ramadan, when Morocco moves to UTC+0.
      # This app has a Ramadan schedule feature; it cannot be vague about the
      # Moroccan clock.
      {:tz, "~> 0.28"},
      # Image handling (libvips): generates the thumb/card/hero variants and
      # doubles as upload validation — a file libvips cannot decode is not an
      # image, whatever its content-type header claims.
      {:image, "~> 0.72"},
      # S3-compatible object storage (MinIO in dev, any S3 in production).
      # Used for SigV4 signing only — transport is OTP's `:httpc` via
      # `Blastek.HTTP`, which keeps hackney (and a HIGH advisory in its SOCKS5
      # path) out of the tree for a client we would barely use.
      {:ex_aws, "~> 2.5"},
      {:ex_aws_s3, "~> 2.5"},
      {:sweet_xml, "~> 0.7"}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get", "ecto.setup"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"]
    ]
  end
end
