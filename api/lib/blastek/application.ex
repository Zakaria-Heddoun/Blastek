defmodule Blastek.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      BlastekWeb.Telemetry,
      Blastek.Repo,
      {DNSCluster, query: Application.get_env(:blastek, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Blastek.PubSub},
      # Start a worker by calling: Blastek.Worker.start_link(arg)
      # {Blastek.Worker, arg},
      # Start to serve requests, typically the last entry
      BlastekWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Blastek.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    BlastekWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
