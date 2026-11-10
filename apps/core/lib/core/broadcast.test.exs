defmodule Core.BroadcastTest do
  @moduledoc """
  A rolled-back write never tells anybody it happened.

  `async: false`: it swaps the injected endpoint, which is global config.
  """

  use ExUnit.Case, async: false

  alias Core.Broadcast

  # Stands in for `Api.Endpoint`, which `core` may not name: it hands each
  # broadcast to the test that registered itself.
  defmodule Endpoint do
    @moduledoc false
    def broadcast(topic, event, payload) do
      send(:broadcast_test, {:broadcast, topic, event, payload})
      :ok
    end
  end

  setup do
    original = Application.get_env(:core, :endpoint)
    Application.put_env(:core, :endpoint, Endpoint)
    Process.register(self(), :broadcast_test)

    on_exit(fn -> Application.put_env(:core, :endpoint, original) end)
  end

  defp tell(id), do: Broadcast.broadcast("lead:" <> id, "lead_moved", %{lead: id})

  describe "after_commit/2" do
    test "broadcasts what a committed transaction returned, and passes it on" do
      result = Broadcast.after_commit({:ok, "l1"}, &tell/1)

      assert result == {:ok, "l1"}
      assert_received {:broadcast, "lead:l1", "lead_moved", %{lead: "l1"}}
    end

    test "says nothing when the transaction failed" do
      assert Broadcast.after_commit({:error, :lead_moved}, &tell/1) == {:error, :lead_moved}
      refute_received {:broadcast, _topic, _event, _payload}
    end

    test "says nothing when a multi failed at any step" do
      failed = {:error, :move, :lead_moved, %{}}

      assert Broadcast.after_commit(failed, &tell/1) == failed
      refute_received {:broadcast, _topic, _event, _payload}
    end
  end

  describe "broadcast/3" do
    test "goes through the injected endpoint" do
      assert Broadcast.broadcast("team:t1", "lead_created", %{lead: "l9"}) == :ok
      assert_received {:broadcast, "team:t1", "lead_created", %{lead: "l9"}}
    end

    test "is a quiet no-op when no endpoint is configured" do
      Application.put_env(:core, :endpoint, nil)

      assert Broadcast.broadcast("team:t1", "lead_created", %{lead: "l9"}) == :ok
      refute_received {:broadcast, _topic, _event, _payload}
    end

    test "is a quiet no-op when the configured endpoint is not loaded" do
      Application.put_env(:core, :endpoint, Not.A.Loaded.Endpoint)

      assert Broadcast.broadcast("team:t1", "lead_created", %{lead: "l9"}) == :ok
    end
  end
end
