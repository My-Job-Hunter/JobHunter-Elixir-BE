defmodule ApiTeam.DevController do
  @moduledoc """
  The dev clock and the sweeps on demand (AQ-04B §7.6, QP4b-1), for any
  signed-in account on a **dev server only**: `ApiTeam.Router` (at
  `/team/v1/dev/…`, where the console calls them) and `Api.Router` (at the
  root `/dev/…`, beside the dev mailbox) compile these routes in only with
  `config :api, dev_routes: true` (dev.exs), so a release has no such route
  and its clock's offset is always 0.

  | Route | Body | Answers |
  |---|---|---|
  | `GET /dev/clock` | — | `{days, offset_days, now}` (`days` and `offset_days` the same number) |
  | `POST /dev/clock` | `{days}`: a whole number of days ahead, 0–3650; `0` resets | `{days, offset_days, now}` |
  | `POST /dev/sweeps` | — | `{now, sweeps: [{name, …what it did}], digests, delivery}`: the follow-up scan, then the warn, archive and purge sweeps, in that order; then (AQ-06 §8.3) the meeting reminders due by the moved clock (`meeting_reminders: {meetings}`), since moving the clock does not move Oban's schedule; then (AQ-07 §9) the approvals' due reminders and auto-approve (`approval_reminders: {reminded, approved}`) and the expiry (`approval_expiry: {expired}`); then (AQ-08 §11.4) the digest scan (`digests: n`) and last the delivery sweep (`delivery: {sent, skipped, failed}`), so what the others raised goes out |
  | `GET /dev/push/json` (root only) | — | the push outbox (AQ-08 QP8-16): `{items: [{at, user_id, app, endpoint, payload: {title, body, tag, url}}]}`, newest first |
  | `DELETE /dev/push/json` (root only) | — | empties it: 204 |
  """

  use Phoenix.Controller, formats: [:json]

  alias Core.Approvals.Act, as: ApprovalAct
  alias Core.Approvals.Reminders, as: ApprovalReminders
  alias Core.Clock
  alias Core.Meetings.Reminders
  alias Core.Notifications.Digests
  alias Core.Retention
  alias Notifire.Delivery
  alias Notifire.Push.Outbox

  action_fallback ApiShared.FallbackController

  def clock(conn, _params), do: json(conn, clock_json())

  def set_clock(conn, params) do
    with {:ok, days} <- days(params["days"]),
         :ok <- set(days),
         do: json(conn, clock_json())
  end

  def sweeps(conn, _params) do
    now = Clock.now()

    sweeps =
      Enum.map(
        Retention.run_all(now) ++
          [
            {"meeting_reminders", Reminders.catch_up(now)},
            {"approval_reminders", ApprovalReminders.catch_up(now)},
            {"approval_expiry", ApprovalAct.expire(now)}
          ],
        fn {name, did} -> Map.put(did, :name, name) end
      )

    digests = Digests.scan(now)
    json(conn, %{now: now, sweeps: sweeps, digests: digests, delivery: Delivery.run(now)})
  end

  def push_outbox(conn, _params) do
    items =
      for item <- Outbox.list() do
        Map.update!(item, :payload, &Map.take(&1, [:title, :body, :tag, :url]))
      end

    json(conn, %{items: items})
  end

  def clear_push_outbox(conn, _params) do
    :ok = Outbox.clear()
    send_resp(conn, :no_content, "")
  end

  defp clock_json do
    days = Clock.offset_days()
    %{days: days, offset_days: days, now: Clock.now()}
  end

  defp set(days) do
    case Clock.set_offset_days(days) do
      :ok -> :ok
      {:error, :disabled} -> {:error, :not_found}
    end
  end

  defp days(nil), do: {:error, {:missing, [:days]}}
  defp days(days) when is_integer(days) and days >= 0 and days <= 3650, do: {:ok, days}

  defp days(days) when is_binary(days) do
    case Integer.parse(days) do
      {n, ""} -> days(n)
      _bad -> invalid()
    end
  end

  defp days(_days), do: invalid()

  defp invalid, do: {:error, {:invalid, %{"days" => ["is a whole number of days, 0 to 3650"]}}}
end
