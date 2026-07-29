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

  scope "/api" do
    pipe_through :api

    forward "/graphql", Absinthe.Plug, schema: BlastekWeb.Schema

    forward "/graphiql", Absinthe.Plug.GraphiQL,
      schema: BlastekWeb.Schema,
      interface: :playground
  end
end
