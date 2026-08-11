defmodule BlastekWeb.Router do
  use BlastekWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
    plug BlastekWeb.RateLimitPlug
    plug BlastekWeb.AuthContext
  end

  # Requests carrying their own signed token instead of a session: raw image
  # bytes on the way to storage, and one-tap links tapped out of a WhatsApp
  # message. Both deliberately skip `AuthContext` and the JSON `accepts`
  # negotiation. Both are rate-limited, because a signed token is unguessable
  # only for as long as nobody is allowed to try a million of them.
  pipeline :signed_token do
    plug BlastekWeb.RateLimitPlug
  end

  scope "/api" do
    pipe_through :signed_token

    put "/uploads", BlastekWeb.UploadController, :create

    # The reader is on a phone and is not signed in — the link is the credential.
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
