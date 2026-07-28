defmodule BlastekWeb.Router do
  use BlastekWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
    plug BlastekWeb.AuthContext
  end

  scope "/api" do
    pipe_through :api

    forward "/graphql", Absinthe.Plug, schema: BlastekWeb.Schema

    forward "/graphiql", Absinthe.Plug.GraphiQL,
      schema: BlastekWeb.Schema,
      interface: :playground
  end
end
