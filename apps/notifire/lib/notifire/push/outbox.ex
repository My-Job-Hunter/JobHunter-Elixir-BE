defmodule Notifire.Push.Outbox do
  @moduledoc """
  The dev push outbox (AQ-08 §7.6, QP8-16; AutoQare's, not mCart's): every
  push `Notifire.Push` sends to a browser is kept here, newest first, the
  way Swoosh's local adapter keeps the dev mailbox, so every check can be
  read by script at `GET /dev/push/json` and emptied by `DELETE`.

  **Dev records and still sends; test only records** (`config :notifire,
  :push_outbox` on in both, `:push_send` off in test). A release has no
  outbox: the process is not started, and `record/1` does nothing. It keeps
  the latest 500.
  """

  use Agent

  @keep 500

  @doc false
  def start_link(_opts), do: Agent.start_link(fn -> [] end, name: __MODULE__)

  @doc "Whether this server keeps an outbox."
  @spec on?() :: boolean()
  def on?, do: Application.get_env(:notifire, :push_outbox, false) == true

  @doc "Keeps one push: `%{at, user_id, app, endpoint, payload}`."
  @spec record(map()) :: :ok
  def record(%{} = item) do
    if running?(), do: Agent.update(__MODULE__, &Enum.take([item | &1], @keep))
    :ok
  end

  @doc "The pushes kept, newest first."
  @spec list() :: [map()]
  def list, do: if(running?(), do: Agent.get(__MODULE__, & &1), else: [])

  @doc "Empties it."
  @spec clear() :: :ok
  def clear do
    if running?(), do: Agent.update(__MODULE__, fn _items -> [] end)
    :ok
  end

  defp running?, do: on?() and Process.whereis(__MODULE__) != nil
end
