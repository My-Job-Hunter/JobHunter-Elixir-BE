defmodule Data.DataCase do
  @moduledoc """
  Test case for anything that touches the database.

  The SQL sandbox rolls every test back, so tests can run `async: true`
  without seeing each other's rows.
  """

  use ExUnit.CaseTemplate

  alias Ecto.Adapters.SQL.Sandbox

  using do
    quote do
      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import Data.DataCase
      import Data.Fixtures

      alias Data.Repo
    end
  end

  setup tags do
    Data.DataCase.setup_sandbox(tags)
    :ok
  end

  @doc "Changeset errors as %{field => [message]}, for readable assertions."
  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _whole, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  @doc "Checks out a sandboxed connection owned for the test's lifetime."
  def setup_sandbox(tags) do
    pid = Sandbox.start_owner!(Data.Repo, shared: not tags[:async])
    on_exit(fn -> Sandbox.stop_owner(pid) end)
  end
end
