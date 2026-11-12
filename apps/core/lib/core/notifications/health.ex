defmodule Core.Notifications.Health do
  @moduledoc """
  Delivery health (AQ-08 §9, QP8-20), Settings › System, **the system
  admin's alone**: the organisation's last 24 hours per channel (sent,
  waiting, skipped, failed) and the latest 20 failures — when, the kind,
  the channel, the person and the error, **never the body**. A failing mail
  key or a dead push shows here before a customer misses a meeting.
  """

  alias Data.Notifications.{Deliveries, Delivery}
  alias Data.Scope
  alias Data.Seeds.Notifications, as: Kinds

  @day 86_400
  @failures 20

  @doc "`GET /team/v1/deliveries/health`; 403 for anyone but the system admin."
  @spec get(Scope.t(), DateTime.t()) :: {:ok, map()} | {:error, term()}
  def get(%Scope{} = scope, %DateTime{} = now) do
    if Scope.admin?(scope) do
      org = Scope.organisation_id(scope)
      since = DateTime.add(now, -@day, :second)
      counts = Deliveries.counts_for_system(org, since)

      {:ok,
       %{
         since: since,
         channels:
           for channel <- Delivery.channels() do
             count = &Map.get(counts, {channel, &1}, 0)

             %{
               channel: channel,
               sent: count.(:sent),
               waiting: count.(:pending),
               skipped: count.(:skipped),
               failed: count.(:failed)
             }
           end,
         failures:
           for f <- Deliveries.failures_for_system(org, @failures) do
             %{
               at: f.at,
               kind: f.kind,
               kind_label: Kinds.label(f.kind),
               channel: f.channel,
               person: %{id: f.user_id, name: f.name},
               error: f.error
             }
           end
       }}
    else
      {:error, {:forbidden, "Only the system admin can see delivery health."}}
    end
  end
end
