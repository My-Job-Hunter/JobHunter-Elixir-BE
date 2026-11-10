defmodule Core.CoreCase do
  @moduledoc """
  For orchestration tests, which do touch the database.

  The pure engines need none of this — a rule that takes `now` and data and
  returns a decision runs without a sandbox, which is the point of keeping it
  pure.
  """

  use ExUnit.CaseTemplate

  alias Ecto.Adapters.SQL.Sandbox

  using do
    quote do
      import Core.CoreCase
      import Data.Fixtures

      alias Data.Repo
    end
  end

  setup tags do
    pid = Sandbox.start_owner!(Data.Repo, shared: not tags[:async])
    on_exit(fn -> Sandbox.stop_owner(pid) end)
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
end
