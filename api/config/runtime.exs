import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/blastek start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :blastek, BlastekWeb.Endpoint, server: true
end

# ## Media storage
#
# Configured here rather than in config/dev.exs so the adapter is chosen when
# the system boots, not when it was compiled — the same image can run against
# MinIO in dev and a real bucket in production.
#
# Presence of S3_BUCKET selects the S3 adapter. Without it the filesystem
# adapter stays in force, which is what keeps a bare checkout and CI working.
bucket = System.get_env("S3_BUCKET")

if config_env() != :test and bucket do
  endpoint_url = System.get_env("S3_ENDPOINT_URL") || "http://localhost:9000"
  %URI{host: host, port: port, scheme: scheme} = URI.parse(endpoint_url)

  config :blastek, :storage_adapter, Blastek.Storage.S3

  config :blastek, Blastek.Storage.S3,
    bucket: bucket,
    endpoint_url: endpoint_url,
    # Browsers resolve a different address than the API does: `minio:9000` is
    # only meaningful inside the compose network.
    public_base_url: System.get_env("S3_PUBLIC_BASE_URL") || endpoint_url

  config :ex_aws, :s3,
    scheme: "#{scheme}://",
    host: host,
    port: port,
    region: System.get_env("S3_REGION") || "us-east-1"

  config :ex_aws,
    access_key_id: System.get_env("S3_ACCESS_KEY_ID"),
    secret_access_key: System.get_env("S3_SECRET_ACCESS_KEY")
end

# ---------------------------------------------------------------------------
# Message delivery (E6 / F0.10)
#
# The chain is assembled from whichever credentials are present, in the order
# WhatsApp → SMS. With neither, `DevLogger` stays in force and messages are
# printed rather than sent — which is what keeps a bare checkout and CI working,
# and is the same bargain the storage adapter makes above.
#
# `DevLogger` logs full message bodies including one-time codes, so production
# refuses to start on it: a deployment that silently logs everybody's login
# codes instead of sending them is worse than a deployment that will not boot.
if config_env() != :test do
  whatsapp = System.get_env("WHATSAPP_TOKEN")
  whatsapp_phone_id = System.get_env("WHATSAPP_PHONE_NUMBER_ID")
  sms_url = System.get_env("SMS_GATEWAY_URL")

  if whatsapp && whatsapp_phone_id do
    config :blastek, Blastek.Notifications.Providers.WhatsApp,
      token: whatsapp,
      phone_number_id: whatsapp_phone_id,
      # Verifies the signature on delivery receipts; without it the webhook
      # rejects everything, which is the safe direction.
      app_secret: System.get_env("WHATSAPP_APP_SECRET"),
      verify_token: System.get_env("WHATSAPP_VERIFY_TOKEN")
  end

  if sms_url do
    config :blastek, Blastek.Notifications.Providers.Sms,
      url: sms_url,
      api_key: System.get_env("SMS_GATEWAY_KEY"),
      sender: System.get_env("SMS_SENDER") || "Blastek"
  end

  chain =
    [
      whatsapp && whatsapp_phone_id && Blastek.Notifications.Providers.WhatsApp,
      sms_url && Blastek.Notifications.Providers.Sms
    ]
    |> Enum.filter(&is_atom/1)
    |> Enum.reject(&is_nil/1)

  case {config_env(), chain} do
    {:prod, []} ->
      raise """
      No notification provider is configured.

      Set WHATSAPP_TOKEN + WHATSAPP_PHONE_NUMBER_ID, or SMS_GATEWAY_URL.
      Running production on DevLogger would write every one-time code to the
      application log instead of sending it.
      """

    {_env, []} ->
      :ok

    {_env, providers} ->
      config :blastek, :notifications_provider, providers
  end

  # Where a one-tap link points. The API and the browser reach different
  # addresses, and a link built from the API's own host is unopenable from a
  # phone — the lesson presigned upload URLs taught in E8.
  config :blastek,
         :public_web_url,
         System.get_env("PUBLIC_WEB_URL") || "http://localhost:5173"
end

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :blastek, Blastek.Repo,
    # ssl: true,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    socket_options: maybe_ipv6

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"
  port = String.to_integer(System.get_env("PORT") || "4000")

  config :blastek, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :blastek, BlastekWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://hexdocs.pm/bandit/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0},
      port: port
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :blastek, BlastekWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://hexdocs.pm/plug/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :blastek, BlastekWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.
end
