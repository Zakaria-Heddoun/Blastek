defmodule BlastekWeb.Router do
  use BlastekWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
    plug BlastekWeb.RateLimitPlug
    plug BlastekWeb.AuthContext
  end

  # Raw image bytes, authorized by a signed token rather than a session, so it
  # deliberately skips `AuthContext` and the JSON `accepts` negotiation.
  pipeline :upload do
    plug BlastekWeb.RateLimitPlug
  end

  scope "/api" do
    pipe_through :upload

    put "/uploads", BlastekWeb.UploadController, :create
  end

  # One-tap links from a WhatsApp message. Authorized by a signed token rather
  # than a session — the reader is on a phone and is not signed in — so this
  # skips `AuthContext` too. Rate-limited, because the token is guessable in
  # exactly the way any signed value is: not at all, but only if nobody is
  # allowed to try a million of them.
  scope "/api" do
    pipe_through :upload

    get "/a/:action/:token", BlastekWeb.ActionController, :act
  end

  # Meta's callbacks. Authenticated by an HMAC over the raw body rather than by
  # a session, so no `AuthContext`; and not rate-limited, because throttling a
  # provider's delivery receipts only means losing them.
  scope "/api/webhooks" do
    get "/whatsapp", BlastekWeb.WhatsAppWebhookController, :verify
    post "/whatsapp", BlastekWeb.WhatsAppWebhookController, :receive
  end

  scope "/api" do
    pipe_through :api

    forward "/graphql", Absinthe.Plug, schema: BlastekWeb.Schema

    forward "/graphiql", Absinthe.Plug.GraphiQL,
      schema: BlastekWeb.Schema,
      interface: :playground
  end
end
