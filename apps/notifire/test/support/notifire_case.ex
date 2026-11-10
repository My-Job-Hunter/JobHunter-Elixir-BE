defmodule Notifire.NotifireCase do
  @moduledoc """
  For delivery tests that read rows, which P7 brings with the
  `notifications` table. The sandbox, as in every case that touches the
  database.
  """

  use ExUnit.CaseTemplate

  alias Ecto.Adapters.SQL.Sandbox

  using do
    quote do
      import Swoosh.TestAssertions
      import Data.Fixtures

      alias Data.Repo
    end
  end

  setup tags do
    pid = Sandbox.start_owner!(Data.Repo, shared: not tags[:async])
    on_exit(fn -> Sandbox.stop_owner(pid) end)
    :ok
  end
end
