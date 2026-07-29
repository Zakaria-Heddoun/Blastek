defmodule BlastekWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :blastek
  use Absinthe.Phoenix.Endpoint

  # GraphQL subscriptions. `check_origin: false` matches the API's CORS posture
  # (it is a token-authenticated API consumed from separate origins), and the
  # socket itself authenticates every connection.
  socket "/socket", BlastekWeb.UserSocket,
    websocket: [check_origin: false],
    longpoll: false

  # The session will be stored in the cookie and signed,
  # this means its contents can be read but not tampered with.
  # Set :encryption_salt if you would also like to encrypt it.
  @session_options [
    store: :cookie,
    key: "_blastek_key",
    signing_salt: "pnbpw9Mc",
    same_site: "Lax"
  ]

  # socket "/live", Phoenix.LiveView.Socket,
  #   websocket: [connect_info: [session: @session_options]],
  #   longpoll: [connect_info: [session: @session_options]]

  # Serve at "/" the static files from "priv/static" directory.
  #
  # You should set gzip to true if you are running phx.digest
  # when deploying your static files in production.
  plug Plug.Static,
    at: "/",
    from: :blastek,
    gzip: false,
    only: BlastekWeb.static_paths()

  # Uploaded media for `Blastek.Storage.Local`. Unused when the S3 adapter is
  # active — there the browser reads straight from the bucket. Cached hard
  # because keys contain a random component, so a key's bytes never change.
  plug Plug.Static,
    at: "/uploads",
    from: {:blastek, "priv/uploads"},
    gzip: false,
    cache_control_for_etags: "public, max-age=31536000, immutable"

  # Code reloading can be explicitly enabled under the
  # :code_reloader configuration of your endpoint.
  if code_reloading? do
    plug Phoenix.CodeReloader
    plug Phoenix.Ecto.CheckRepoStatus, otp_app: :blastek
  end

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options
  plug CORSPlug
  plug BlastekWeb.Router
end
