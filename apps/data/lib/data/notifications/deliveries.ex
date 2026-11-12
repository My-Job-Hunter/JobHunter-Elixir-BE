defmodule Data.Notifications.Deliveries do
  @moduledoc """
  The deliveries ledger (AQ-08 §5, QP8-2), storage only. `core` writes the
  planned rows in the notification's transaction (`insert_planned/4`) and
  claims the extension's (`claim_extension/3`); `notifire` takes the due
  push and email rows one at a time under `FOR UPDATE SKIP LOCKED`
  (`next_due_for_system/1`), so two sweeps never take the same row, and
  records what became of each. The rules are theirs; this module only
  reads and writes.
  """

  import Ecto.Query, warn: false

  alias Data.Notifications.{Delivery, Kind, Notification}
  alias Data.Repo

  @sweep_channels [:push, :email]

  # ── Planning (core) ─────────────────────────────────────────────────────────

  @doc """
  Writes a new notification's planned rows (`[%{channel, deliver_after,
  deferred}]`); `ics` rides on the email row only. **A row already there
  for the pair is left alone**: never twice. Answers the rows written.
  """
  @spec insert_planned(Notification.t(), [map()], String.t() | nil, DateTime.t()) ::
          [Delivery.t()]
  def insert_planned(_notification, [], _ics, _now), do: []

  def insert_planned(%Notification{} = n, planned, ics, %DateTime{} = now) do
    rows =
      for p <- planned do
        %{
          id: Uniq.UUID.uuid7(),
          organisation_id: n.organisation_id,
          notification_id: n.id,
          user_id: n.user_id,
          channel: p.channel,
          state: :pending,
          deliver_after: usec(p.deliver_after),
          deferred: p.deferred,
          attempts: 0,
          ics: if(p.channel == :email, do: ics),
          inserted_at: usec(now),
          updated_at: usec(now)
        }
      end

    {_count, written} =
      Repo.insert_all(Delivery, rows,
        on_conflict: :nothing,
        conflict_target: [:notification_id, :channel],
        returning: true
      )

    written
  end

  @doc "A notification's rows, in channel order: what a test or a run asks."
  @spec for_notification(binary()) :: [Delivery.t()]
  def for_notification(notification_id) do
    from(d in Delivery, where: d.notification_id == ^notification_id)
    |> Repo.all()
    |> Enum.sort_by(&Enum.find_index(Delivery.channels(), fn c -> c == &1.channel end))
  end

  @doc "A person's rows of every state, newest first: what a test or a run asks."
  @spec for_user(binary()) :: [Delivery.t()]
  def for_user(user_id) do
    from(d in Delivery, where: d.user_id == ^user_id, order_by: [desc: d.inserted_at])
    |> Repo.all()
  end

  @doc "A person's rows still held by quiet hours, with their notification and kind."
  @spec held(binary()) :: [Delivery.t()]
  def held(user_id) do
    from(d in Delivery,
      where: d.user_id == ^user_id and d.state == :pending and d.deferred == true,
      preload: [notification: [notification_kind: :notification_group]]
    )
    |> Repo.all()
  end

  @doc "Moves a held row to its new time; `deferred` says whether quiet hours still hold it."
  @spec replan(Delivery.t(), DateTime.t(), boolean(), DateTime.t()) :: :ok
  def replan(%Delivery{id: id}, %DateTime{} = deliver_after, deferred?, %DateTime{} = now) do
    from(d in Delivery, where: d.id == ^id and d.state == :pending)
    |> Repo.update_all(
      set: [deliver_after: usec(deliver_after), deferred: deferred?, updated_at: usec(now)]
    )

    :ok
  end

  # ── Sending (notifire) ──────────────────────────────────────────────────────

  @doc """
  The oldest due `pending` push or email row nobody else holds, locked
  (`FOR UPDATE SKIP LOCKED`) **for the calling transaction**, with its
  notification, kind and group; `nil` when none is due.
  """
  @spec next_due_for_system(DateTime.t()) :: Delivery.t() | nil
  def next_due_for_system(%DateTime{} = now) do
    now = usec(now)

    from(d in Delivery,
      where: d.state == :pending and d.channel in ^@sweep_channels and d.deliver_after <= ^now,
      order_by: [asc: d.deliver_after, asc: d.id],
      limit: 1,
      lock: "FOR UPDATE SKIP LOCKED"
    )
    |> Repo.one()
    |> Repo.preload(notification: [notification_kind: :notification_group])
  end

  @doc "Sent."
  @spec mark_sent(Delivery.t(), DateTime.t()) :: :ok
  def mark_sent(%Delivery{} = d, %DateTime{} = now),
    do: set(d, state: :sent, sent_at: usec(now), error: nil, updated_at: usec(now))

  @doc "Skipped, and why (`:read`, `:no_target`, `:preference_off`)."
  @spec mark_skipped(Delivery.t(), atom(), DateTime.t()) :: :ok
  def mark_skipped(%Delivery{} = d, reason, %DateTime{} = now),
    do: set(d, state: :skipped, skip_reason: reason, updated_at: usec(now))

  @doc """
  A failed attempt: `attempts` + 1 and the error kept (cut to 500
  characters). Under `max` attempts the row stays `pending`, due at
  `retry_at`; the last one makes it `failed`. Answers the state it is in.
  """
  @spec record_failure(Delivery.t(), String.t(), DateTime.t(), DateTime.t(), pos_integer()) ::
          :pending | :failed
  def record_failure(%Delivery{} = d, error, %DateTime{} = now, %DateTime{} = retry_at, max) do
    attempts = d.attempts + 1
    error = String.slice(error, 0, 500)

    if attempts >= max do
      :ok = set(d, state: :failed, attempts: attempts, error: error, updated_at: usec(now))
      :failed
    else
      :ok =
        set(d,
          attempts: attempts,
          error: error,
          deliver_after: usec(retry_at),
          deferred: false,
          updated_at: usec(now)
        )

      :pending
    end
  end

  @doc """
  `pending` extension rows due more than a day before `now`: nobody's
  extension was running (AQ-08 §7.5). Marked `skipped · no_target`;
  answers how many.
  """
  @spec skip_unclaimed_for_system(DateTime.t()) :: non_neg_integer()
  def skip_unclaimed_for_system(%DateTime{} = now) do
    cutoff = now |> DateTime.add(-86_400, :second) |> usec()

    {count, _rows} =
      from(d in Delivery,
        where: d.state == :pending and d.channel == :extension and d.deliver_after < ^cutoff
      )
      |> Repo.update_all(set: [state: :skipped, skip_reason: :no_target, updated_at: usec(now)])

    count
  end

  # ── The extension's claim (core) ────────────────────────────────────────────

  @doc """
  Claims the person's due `pending` extension rows **in one statement**
  (`UPDATE … RETURNING`, the rows `sent`), oldest first, at most `limit`;
  a second poll, or a second device, gets none of them. Rows in a group
  whose extension switch is off (`off_groups`) are skipped
  (`preference_off`) first. Answers the claimed rows' notifications, oldest
  first.
  """
  @spec claim_extension(binary(), DateTime.t(), pos_integer(), [String.t()]) :: [Notification.t()]
  def claim_extension(user_id, %DateTime{} = now, limit, off_groups \\ []) do
    now = usec(now)
    _skipped = skip_off(user_id, now, off_groups)

    due =
      from(d in Delivery,
        where:
          d.user_id == ^user_id and d.channel == :extension and d.state == :pending and
            d.deliver_after <= ^now,
        order_by: [asc: d.deliver_after, asc: d.id],
        limit: ^limit,
        lock: "FOR UPDATE SKIP LOCKED",
        select: d.id
      )

    {_count, ids} =
      from(d in Delivery, where: d.id in subquery(due), select: d.notification_id)
      |> Repo.update_all(set: [state: :sent, sent_at: now, updated_at: now])

    from(n in Notification, where: n.id in ^ids, order_by: [asc: n.inserted_at, asc: n.id])
    |> Repo.all()
  end

  defp skip_off(_user_id, _now, []), do: 0

  defp skip_off(user_id, now, off_groups) do
    kinds = from(k in Kind, where: k.notification_group_key in ^off_groups, select: k.key)

    notifications =
      from(n in Notification,
        where: n.user_id == ^user_id and n.notification_kind_key in subquery(kinds),
        select: n.id
      )

    {count, _rows} =
      from(d in Delivery,
        where:
          d.user_id == ^user_id and d.channel == :extension and d.state == :pending and
            d.notification_id in subquery(notifications)
      )
      |> Repo.update_all(set: [state: :skipped, skip_reason: :preference_off, updated_at: now])

    count
  end

  # ── Health (core) ───────────────────────────────────────────────────────────

  @doc """
  An organisation's rows inserted since `since`, counted per channel and
  state: `%{{channel, state} => n}`.
  """
  @spec counts_for_system(binary(), DateTime.t()) :: %{{atom(), atom()} => non_neg_integer()}
  def counts_for_system(organisation_id, %DateTime{} = since) do
    since = usec(since)

    from(d in Delivery,
      where: d.organisation_id == ^organisation_id and d.inserted_at >= ^since,
      group_by: [d.channel, d.state],
      select: {{d.channel, d.state}, count(d.id)}
    )
    |> Repo.all()
    |> Map.new()
  end

  @doc """
  An organisation's latest `limit` failures, newest first: the `failed`
  rows and the `pending` ones that carry an error, with their notification's
  kind and the person (never the notification's words).
  """
  @spec failures_for_system(binary(), pos_integer()) :: [map()]
  def failures_for_system(organisation_id, limit) do
    from(d in Delivery,
      join: n in assoc(d, :notification),
      join: u in assoc(d, :user),
      join: p in assoc(u, :person),
      where:
        d.organisation_id == ^organisation_id and
          (d.state == :failed or (d.state == :pending and not is_nil(d.error))),
      order_by: [desc: d.updated_at, desc: d.id],
      limit: ^limit,
      select: %{
        at: d.updated_at,
        kind: n.notification_kind_key,
        channel: d.channel,
        user_id: u.id,
        name: p.display_name,
        error: d.error
      }
    )
    |> Repo.all()
  end

  defp set(%Delivery{id: id}, fields) do
    from(d in Delivery, where: d.id == ^id) |> Repo.update_all(set: fields)
    :ok
  end

  # The columns are `timestamptz` with microseconds, and Ecto dumps only a
  # `DateTime` of that precision: a rule's `~U[… 08:00:00Z]` is widened here.
  defp usec(%DateTime{microsecond: {us, _precision}} = at), do: %{at | microsecond: {us, 6}}
end
