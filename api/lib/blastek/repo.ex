defmodule Blastek.Repo do
  use Ecto.Repo,
    otp_app: :blastek,
    adapter: Ecto.Adapters.Postgres
end
