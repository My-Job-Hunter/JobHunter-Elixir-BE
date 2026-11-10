defmodule Core.Broadcast do
  @moduledoc """
  Pushing changes to whoever is watching.

  **After commit, never inside the transaction.** A broadcast from inside
  `Repo.transaction` can reach a subscriber before the commit lands; the client
  then refetches a row that does not exist yet and renders a gap. Every caller
  runs on the value the transaction *returned*, which is what `after_commit/2`
  makes the easy shape:

      Repo.transaction(fn -> ... end)
      |> Broadcast.after_commit(fn lead ->
        Broadcast.broadcast("lead:" <> lead.id, "lead_moved", %{lead: lead.id})
      end)

  **Payloads are ids** (PLAN §15.6). A client re-reads through the API, where
  the scope applies; it is never handed a row, so a broadcast cannot leak a
  staff-only field. The topics (`user:`, `team:`, `customer:`, `lead:`) and
  their closed event lists arrive with their channels, from P1.
  """

  @doc """
  Runs the broadcast only if the transaction committed.

  `{:error, _}` broadcasts nothing, so a rolled-back write never tells anybody
  it happened. The result passes through untouched.
  """
  @spec after_commit({:ok, any()} | {:error, any()} | {:error, any(), any(), any()}, (any() ->
                                                                                        any())) ::
          {:ok, any()} | {:error, any()} | {:error, any(), any(), any()}
  def after_commit({:ok, result} = ok, fun) when is_function(fun, 1) do
    fun.(result)
    ok
  end

  def after_commit(other, fun) when is_function(fun, 1), do: other

  @doc """
  Broadcasts `event` with `payload` on `topic`, through the endpoint.

  **Through the endpoint, never `Phoenix.PubSub` by hand.**
  `Endpoint.broadcast/3` attaches the fastlane: subscribed channel processes
  are skipped and the socket transport serialises the message once for
  everybody. A raw PubSub publish has no fastlane, so the struct lands in each
  channel process's mailbox and Phoenix routes it through a `handle_out/3`
  these channels have no reason to define — which in AutoCare crashed every
  broadcast to a joined client, silently.

  Answers `:ok` when no endpoint is configured or loaded (a `core`-only test
  run, a release that serves no HTTP): nobody is listening on a socket, so
  there is nothing to tell.
  """
  @spec broadcast(String.t(), String.t(), map()) :: :ok | {:error, term()}
  def broadcast(topic, event, payload)
      when is_binary(topic) and is_binary(event) and is_map(payload) do
    endpoint = endpoint()

    # **Configured *and* loaded.** `config :core, :endpoint` names
    # `Api.Endpoint`, which `core` cannot depend on — so in a `core`-only test
    # run the module genuinely is not there.
    if endpoint && Code.ensure_loaded?(endpoint) do
      endpoint.broadcast(topic, event, payload)
    else
      :ok
    end
  end

  @doc """
  Which endpoint does the broadcasting.

  **Injected through config, never named directly.** `api` depends on `core`,
  so `core` naming `Api.Endpoint` is the one direction the umbrella exists to
  refuse — the same reason `Core.Auth.Guardian` takes its `user_loader` as
  config.
  """
  @spec endpoint() :: module() | nil
  def endpoint, do: Application.get_env(:core, :endpoint)
end
