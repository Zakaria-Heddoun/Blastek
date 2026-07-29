defmodule BlastekWeb.ChannelCase do
  @moduledoc """
  Test case for channels — used by the GraphQL subscription tests.
  """
  use ExUnit.CaseTemplate

  using do
    quote do
      import Phoenix.ChannelTest
      import BlastekWeb.ChannelCase

      alias Blastek.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query

      @endpoint BlastekWeb.Endpoint
    end
  end

  setup _tags do
    # Subscriptions run in the endpoint's processes, not the test process, so
    # the sandbox connection has to be shared for them to see the test's data.
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Blastek.Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    :ok
  end
end
