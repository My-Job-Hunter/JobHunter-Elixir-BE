defmodule Core.Notifications.Deliveries do
  @moduledoc """
  The seam's second half (AQ-08 §7.1, QP8-1): **a new notification's
  deliveries planned in its own transaction**, as mCart's `put_alert` does.
  `Core.Notifications.ensure/2` calls `plan/3` when the row is new; nothing
  else writes the ledger's rows.

  It reads what the pure rule needs — the kind and its group, the person's
  switches for that group, what they can have (a browser turned on in their
  app, a connected device, staff or customer), their quiet hours and zone —
  hands it to `Core.Notifications.Channels.plan/5`, writes one row per
  channel, and **when a push or email row is due now enqueues the delivery
  worker by its name in config** (`config :core, :delivery_worker`), unique
  for 2 seconds, as mCart's `deliver_soon` does. The job is inserted in the
  same transaction, so a notification that rolls back sends nothing.

  `replan_held/3` is the other half of a changed window (§11.4): `PUT
  /me/settings` moves the person's held rows to the new window's end, or
  lets them go now.
  """

  alias Core.Notifications.Channels
  alias Data.Devices
  alias Data.Notifications
  alias Data.Notifications.{Deliveries, Kind, Notification, Preferences, PushSubscriptions}

  require Logger

  @doc """
  Plans and writes a new notification's rows; `ics` (a meeting's calendar
  file) rides on its email row. Answers the rows written (none for a kind
  whose channels are in-app and the digest alone).
  """
  @spec plan(Notification.t(), String.t() | nil, DateTime.t()) :: list()
  def plan(%Notification{} = n, ics, %DateTime{} = now) do
    with %Kind{} = kind <- Notifications.get_kind(n.notification_kind_key),
         true <- beyond_the_bell?(kind),
         %{} = who <- Notifications.recipient(n.user_id) do
      group = kind.notification_group_key

      planned =
        Channels.plan(
          kind_for_plan(kind),
          Preferences.switches(n.user_id, group),
          targets(who),
          settings(who),
          now
        )

      rows = Deliveries.insert_planned(n, planned, ics, now)
      if Enum.any?(rows, &due_now?(&1, now)), do: deliver_soon()
      rows
    else
      _nothing_to_plan -> []
    end
  end

  @doc """
  Re-plans the person's rows held by quiet hours after their window changed
  (AQ-08 §11.4): each is due when it would have been without the window,
  then held again only if the new window holds it. Answers how many moved.
  """
  @spec replan_held(binary(), DateTime.t()) :: non_neg_integer()
  def replan_held(user_id, %DateTime{} = now) do
    case {Deliveries.held(user_id), Notifications.recipient(user_id)} do
      {[], _who} ->
        0

      {_rows, nil} ->
        0

      {rows, who} ->
        settings = settings(who)

        moved =
          for row <- rows do
            kind = kind_for_plan(row.notification.notification_kind)
            plan = Channels.hold(kind, row.channel, unheld_at(kind, row, now), settings)
            :ok = Deliveries.replan(row, plan.deliver_after, plan.deferred, now)
            Map.merge(row, plan)
          end

        if Enum.any?(moved, &due_now?(&1, now)), do: deliver_soon()
        length(moved)
    end
  end

  # When the row would go with no quiet hours at all: an email still keeps
  # its wait from when it was written.
  defp unheld_at(kind, %{channel: :email, inserted_at: written}, now) do
    due =
      if Channels.email_at_once?(kind.group),
        do: written,
        else: DateTime.add(written, Channels.email_wait_s(), :second)

    later(due, now)
  end

  defp unheld_at(_kind, _row, now), do: now

  defp later(a, b), do: if(DateTime.after?(a, b), do: a, else: b)

  @doc """
  Enqueues the delivery worker now, by its configured name (`config :core,
  :delivery_worker`; `core` never names a `notifire` module), unique for 2
  seconds so a burst of notifications is one sweep.
  """
  @spec deliver_soon() :: :ok
  def deliver_soon do
    case Application.get_env(:core, :delivery_worker) do
      nil ->
        :ok

      worker ->
        %{}
        |> Oban.Job.new(worker: worker, queue: :notifications, unique: [period: 2])
        |> Oban.insert()
        |> case do
          {:ok, _job} -> :ok
          {:error, reason} -> Logger.error("could not enqueue delivery: #{inspect(reason)}")
        end

        :ok
    end
  end

  # ── Inputs ──────────────────────────────────────────────────────────────────

  defp beyond_the_bell?(%Kind{default_channels: channels}),
    do: Enum.any?(channels, &(&1 in ~w(push email extension)))

  @doc false
  @spec kind_for_plan(Kind.t()) :: Channels.kind()
  def kind_for_plan(%Kind{} = kind) do
    %{
      key: kind.key,
      group: kind.notification_group_key,
      channels: kind.default_channels,
      can_ignore_quiet_hours: kind.can_ignore_quiet_hours,
      can_disable: kind.notification_group.can_disable
    }
  end

  # What the person can have (§4, QP8-7): push needs a browser turned on in
  # their app; the extension a connected device, staff only; email always.
  defp targets(who) do
    %{
      push: PushSubscriptions.any?(who.user.id, who.app),
      email: true,
      extension: not who.customer? and Devices.connected?(who.user.id)
    }
  end

  defp settings(who) do
    %{
      quiet_hours_start: who.settings.quiet_hours_start,
      quiet_hours_end: who.settings.quiet_hours_end,
      zone: who.zone
    }
  end

  defp due_now?(%{channel: channel, deliver_after: at}, now),
    do: channel in [:push, :email] and not DateTime.after?(at, now)
end
