defmodule Data.Notifications do
  @moduledoc """
  Notification rows, their kinds and groups (AQ-02 §5.2). Storage only:
  who is told what, in which words, is `Core.Tasks`'s; who reads which row
  is `Core.Notifications`'s (each person their own).

  **`ensure/2` is the only write of a row**, and since P8 it is reached only
  through `Core.Notifications.ensure/2`, which plans a new row's deliveries
  in the same transaction (AQ-08 §7.1). Keyed on `(user_id,
  dedupe_key)`, a second ensure answers the row already there and inserts
  nothing. It inserts with `ON CONFLICT DO NOTHING` rather than catching a
  unique violation, because a violation aborts the surrounding transaction
  in Postgres — and every ensure runs inside the transaction of the change
  that raised it.
  """

  import Ecto.Query, warn: false

  alias Data.Notifications.{Group, Kind, Notification}
  alias Data.Repo
  alias Data.Scope

  @preload [:notification_kind, actor_user: [person: :photo]]

  # ── Writes ──────────────────────────────────────────────────────────────────

  @doc """
  Writes the notification unless `(user_id, dedupe_key)` already exists, and
  answers the row either way: `is_new` says whether this call wrote it.
  `organisation_id` defaults to the scope's.
  """
  @spec ensure(Scope.t(), map()) :: {:ok, Notification.t()} | {:error, Ecto.Changeset.t()}
  def ensure(%Scope{} = scope, attrs) do
    attrs = attrs |> Map.new() |> Map.put_new(:organisation_id, Scope.organisation_id(scope))
    changeset = Notification.changeset(%Notification{}, attrs)

    with {:ok, attempt} <-
           Repo.insert(changeset,
             on_conflict: :nothing,
             conflict_target: [:user_id, :dedupe_key]
           ) do
      row = Repo.get_by!(Notification, user_id: attempt.user_id, dedupe_key: attempt.dedupe_key)
      {:ok, %{row | is_new: row.id == attempt.id}}
    end
  end

  @doc "Marks one of the person's own read; `nil` when it is not theirs."
  @spec mark_read(binary(), binary(), DateTime.t()) :: Notification.t() | nil
  def mark_read(user_id, id, %DateTime{} = at) do
    with {:ok, uuid} <- Ecto.UUID.cast(id),
         %Notification{} = n <- Repo.get_by(Notification, id: uuid, user_id: user_id) do
      if n.read_at, do: n, else: n |> Ecto.Changeset.change(read_at: at) |> Repo.update!()
    else
      _other -> nil
    end
  end

  @doc "Marks every unread one of the person's read, in one statement. Answers how many."
  @spec mark_all_read(binary(), DateTime.t()) :: non_neg_integer()
  def mark_all_read(user_id, %DateTime{} = at) do
    {count, _rows} =
      from(n in Notification, where: n.user_id == ^user_id and is_nil(n.read_at))
      |> Repo.update_all(set: [read_at: at, updated_at: at])

    count
  end

  # ── Reads ───────────────────────────────────────────────────────────────────

  @doc """
  One page of a person's notifications, newest first, by keyset: `after`
  is the `{inserted_at, id}` of the last row already shown. Options:
  `group` (a group key), `unread` (boolean), `after`, `limit`. Answers
  `{rows, more?}`.
  """
  @spec page(binary(), keyword()) :: {[Notification.t()], boolean()}
  def page(user_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 30)

    rows =
      from(n in Notification,
        where: n.user_id == ^user_id,
        order_by: [desc: n.inserted_at, desc: n.id],
        limit: ^(limit + 1),
        preload: ^@preload
      )
      |> in_group(Keyword.get(opts, :group))
      |> unread(Keyword.get(opts, :unread, false))
      |> after_key(Keyword.get(opts, :after))
      |> Repo.all()

    {Enum.take(rows, limit), length(rows) > limit}
  end

  defp in_group(query, nil), do: query

  defp in_group(query, group),
    do:
      where(
        query,
        [n],
        n.notification_kind_key in subquery(
          from(k in Kind, where: k.notification_group_key == ^group, select: k.key)
        )
      )

  defp unread(query, true), do: where(query, [n], is_nil(n.read_at))
  defp unread(query, _all), do: query

  defp after_key(query, nil), do: query

  defp after_key(query, {%DateTime{} = at, id}),
    do: where(query, [n], n.inserted_at < ^at or (n.inserted_at == ^at and n.id < ^id))

  @doc "How many of the person's are unread: the bell."
  @spec unread_count(binary()) :: non_neg_integer()
  def unread_count(user_id) do
    from(n in Notification, where: n.user_id == ^user_id and is_nil(n.read_at))
    |> Repo.aggregate(:count)
  end

  @doc "The groups that have rows for this person, in their order: the chips."
  @spec groups_with_rows(binary()) :: [Group.t()]
  def groups_with_rows(user_id) do
    from(g in Group,
      where:
        g.key in subquery(
          from(n in Notification,
            join: k in assoc(n, :notification_kind),
            where: n.user_id == ^user_id,
            distinct: true,
            select: k.notification_group_key
          )
        ),
      order_by: [asc: g.position, asc: g.key]
    )
    |> Repo.all()
  end

  @doc "Whether the person has a row with this dedupe key (the digest's once a day)."
  @spec exists?(binary(), String.t()) :: boolean()
  def exists?(user_id, dedupe_key) do
    from(n in Notification, where: n.user_id == ^user_id and n.dedupe_key == ^dedupe_key)
    |> Repo.exists?()
  end

  @doc "One row by id with its kind and group: what `notifire` delivers."
  @spec get_for_system(binary()) :: Notification.t() | nil
  def get_for_system(id) do
    Notification
    |> Repo.get(id)
    |> Repo.preload(notification_kind: :notification_group)
  end

  @doc """
  Who a notification goes to, as delivery needs them (AQ-08 §4): the
  account with its person, whether they are a customer (a `customers` row
  holds their login: the portal is theirs, push goes to `client`, links open
  the portal), their zone (`persons.timezone`) and their settings (the code
  defaults when no row).
  """
  @spec recipient(binary()) :: map() | nil
  def recipient(user_id) do
    case Data.Accounts.get_user(user_id) do
      nil ->
        nil

      user ->
        customer? =
          Repo.exists?(from(c in Data.Customers.Customer, where: c.user_id == ^user.id))

        %{
          user: user,
          customer?: customer?,
          app: if(customer?, do: :client, else: :team),
          zone: (user.person && user.person.timezone) || "Etc/UTC",
          settings: Data.Accounts.get_settings(user.id)
        }
    end
  end

  @doc """
  The accounts the digest scan looks at (AQ-08 §7.4): live, with the digest
  on (no settings row means on, at 08:00), as `%{user_id, digest_time,
  zone}`.
  """
  @spec digest_candidates_for_system() :: [map()]
  def digest_candidates_for_system do
    from(u in Data.Accounts.User,
      join: p in assoc(u, :person),
      left_join: s in Data.Accounts.UserSettings,
      on: s.user_id == u.id,
      where:
        is_nil(u.suspended_at) and is_nil(u.deactivated_at) and is_nil(u.purged_at) and
          (is_nil(s.user_id) or s.digest_on == true),
      select: %{user_id: u.id, digest_time: s.digest_time, zone: p.timezone}
    )
    |> Repo.all()
    |> Enum.map(&%{&1 | digest_time: &1.digest_time || ~T[08:00:00]})
  end

  @doc "When the person's latest row of `kind` was written, or `nil`."
  @spec latest_at(binary(), String.t()) :: DateTime.t() | nil
  def latest_at(user_id, kind) do
    from(n in Notification,
      where: n.user_id == ^user_id and n.notification_kind_key == ^kind,
      select: max(n.inserted_at)
    )
    |> Repo.one()
  end

  @doc """
  The person's unread rows since `since` whose kind has the digest among its
  channels, in `groups`, oldest first, with their group: what a digest says.
  """
  @spec unread_for_digest(binary(), DateTime.t(), [String.t()]) :: [map()]
  def unread_for_digest(_user_id, _since, []), do: []

  def unread_for_digest(user_id, %DateTime{microsecond: {us, _p}} = since, groups) do
    since = %{since | microsecond: {us, 6}}

    from(n in Notification,
      join: k in assoc(n, :notification_kind),
      where:
        n.user_id == ^user_id and is_nil(n.read_at) and n.inserted_at > ^since and
          "digest" in k.default_channels and k.notification_group_key in ^groups,
      order_by: [asc: n.inserted_at, asc: n.id],
      select: %{
        id: n.id,
        title: n.title,
        group: k.notification_group_key,
        organisation_id: n.organisation_id,
        inserted_at: n.inserted_at
      }
    )
    |> Repo.all()
  end

  @doc "A person's rows for one task: what a test or a run asks after a verb."
  @spec for_task(binary(), binary()) :: [Notification.t()]
  def for_task(user_id, task_id) do
    from(n in Notification,
      where: n.user_id == ^user_id and n.task_id == ^task_id,
      order_by: [asc: n.inserted_at]
    )
    |> Repo.all()
  end

  # ── Kinds and groups (the reference seed) ───────────────────────────────────

  @doc """
  Writes a group by key, **updating one that exists in place** (AQ-08 §14:
  groups and kinds are reference data owned by code). Answers `:inserted`,
  `:updated` or `:kept` (already as written).
  """
  @spec upsert_group(map()) :: :inserted | :updated | :kept
  def upsert_group(attrs), do: upsert(Group, attrs)

  @doc """
  Writes a kind by key, **updating one that exists in place**: its group,
  `default_channels` and `can_ignore_quiet_hours`, so a changed default
  reaches a database seeded before the change (AQ-08 §14). Answers
  `:inserted`, `:updated` or `:kept`.
  """
  @spec upsert_kind(map()) :: :inserted | :updated | :kept
  def upsert_kind(attrs), do: upsert(Kind, attrs)

  defp upsert(schema, attrs) do
    case Repo.get(schema, attrs.key) do
      nil ->
        schema |> struct() |> schema.changeset(attrs) |> Repo.insert!()
        :inserted

      there ->
        changeset = schema.changeset(there, attrs)

        if changeset.changes == %{} do
          :kept
        else
          Repo.update!(changeset)
          :updated
        end
    end
  end

  @doc "A kind by key, with its group; `nil` for a key nobody seeded."
  @spec get_kind(String.t()) :: Kind.t() | nil
  def get_kind(key) when is_binary(key),
    do: Kind |> Repo.get(key) |> Repo.preload(:notification_group)

  @doc "Every kind with its group, by key."
  @spec kinds_with_groups() :: [Kind.t()]
  def kinds_with_groups,
    do: Repo.all(from(k in Kind, order_by: k.key, preload: :notification_group))

  @doc "A group by key, or `nil`."
  @spec get_group(String.t()) :: Group.t() | nil
  def get_group(key) when is_binary(key), do: Repo.get(Group, key)
  def get_group(_key), do: nil

  @doc "Every kind, by key."
  @spec kinds() :: [Kind.t()]
  def kinds, do: Repo.all(from(k in Kind, order_by: k.key))

  @doc "Every group, in order."
  @spec groups() :: [Group.t()]
  def groups, do: Repo.all(from(g in Group, order_by: [asc: g.position, asc: g.key]))
end
