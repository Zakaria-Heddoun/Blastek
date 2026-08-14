defmodule Blastek.DataCase do
  @moduledoc """
  This module defines the setup for tests requiring
  access to the application's data layer.

  You may define functions here to be used as helpers in
  your tests.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use Blastek.DataCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      alias Blastek.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import Blastek.DataCase
    end
  end

  setup tags do
    Blastek.DataCase.setup_sandbox(tags)
    :ok
  end

  @doc """
  Sets up the sandbox based on the test tags.
  """
  def setup_sandbox(tags) do
    opts = [shared: not tags[:async]]

    # A test may raise the sandbox's own 120-second ownership timeout with
    # `@moduletag ownership_timeout: …`. Only one test needs it — the search
    # performance gate builds a 7 000-row fixture before it measures anything —
    # and without it a *loaded machine* fails that gate rather than a slow
    # query, which is precisely the confusion the gate exists to avoid.
    opts =
      case tags[:ownership_timeout] do
        nil -> opts
        timeout -> Keyword.put(opts, :ownership_timeout, timeout)
      end

    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Blastek.Repo, opts)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
  end

  @doc """
  A helper that transforms changeset errors into a map of messages.

      assert {:error, changeset} = Accounts.create_user(%{password: "short"})
      assert "password is too short" in errors_on(changeset).password
      assert %{password: ["password is too short"]} = errors_on(changeset)

  """
  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
