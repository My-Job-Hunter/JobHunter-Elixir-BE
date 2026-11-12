defmodule Core.Notifications do
  @moduledoc """
  The bell (AQ-02 P2.0, §7.1): a person's notifications, **each person
  their own** — every read and write is bound to the scope's user, so
  nobody reads or clears another's. Served to the console and the portal
  alike. Reading one, or all, tells the person's other tabs
  (`notifications_read {}` on `user:<id>`), so two bells stay equal.

  ## The seam (AQ-08 §7.1, QP8-1)

  **Every notice module writes through `ensure/2`**: tasks, leads,
  follow-ups, retention, conversations, meetings and approvals. It ensures
  the row by its dedupe key (`Data.Notifications.ensure/2`) and, **when the
  row is new, plans its deliveries in the same transaction**
  (`Core.Notifications.Deliveries.plan/3`): one `notification_deliveries`
  row per channel beyond the bell, quiet hours and email's wait applied,
  and the delivery worker enqueued by its configured name when a push or
  email is due now. A row ensured again plans nothing: never twice.

  The rest of P8 sits beside it: the settings (`Settings`), push on a
  browser (`Push`), the extension's pop-ups (`PopUps`), the digest
  (`Digest`, `Digests`), quiet hours (`QuietHours`) and delivery health
  (`Health`). `notifire` delivers from the ledger and never calls here.
  """

  alias Core.Clock
  alias Core.Media
  alias Core.Notifications.Deliveries
  alias Core.Realtime
  alias Core.Tasks.Words
  alias Data.Accounts.Person
  alias Data.Notifications
  alias Data.Notifications.Notification
  alias Data.Repo
  alias Data.Scope

  @default_limit 30

  # ── The seam ────────────────────────────────────────────────────────────────

  @doc """
  Ensures the notification (`attrs` as `Data.Notifications.ensure/2` takes
  them) and, when it is new, plans its deliveries at `now` in the same
  transaction. `attrs[:ics]`, a meeting's calendar file, rides on the
  email row. Answers the row either way, `is_new` saying whether this call
  wrote it.
  """
  @spec ensure(Scope.t(), map(), DateTime.t()) ::
          {:ok, Notification.t()} | {:error, Ecto.Changeset.t()}
  def ensure(%Scope{} = scope, attrs, %DateTime{} = now \\ Clock.now()) do
    {ics, attrs} = attrs |> Map.new() |> Map.pop(:ics)

    Repo.transaction(fn ->
      case Notifications.ensure(scope, attrs) do
        {:ok, %Notification{is_new: true} = row} ->
          _rows = Deliveries.plan(row, ics, now)
          row

        {:ok, row} ->
          row

        {:error, changeset} ->
          Repo.rollback(changeset)
      end
    end)
  end

  @doc "The socket events new rows make (`notification_created {id}` on `user:<id>`), sent now."
  @spec created([Notification.t()]) :: :ok
  def created(rows) do
    rows
    |> Enum.map(&Realtime.to_user(&1.user_id, "notification_created", %{id: &1.id}))
    |> Realtime.send_all()

    :ok
  end

  @doc """
  `GET /notifications?group&unread&cursor`: a keyset page, newest first,
  `%{items, next_cursor}`; `next_cursor` is `nil` on the last page.
  """
  @spec page(Scope.t(), map()) :: {:ok, map()} | {:error, term()}
  def page(%Scope{} = scope, params) do
    params = Map.new(params, fn {k, v} -> {to_string(k), v} end)

    with {:ok, user_id} <- me(scope),
         {:ok, after_key} <- cursor(params["cursor"]) do
      {rows, more?} =
        Notifications.page(user_id,
          group: Utils.presence(params["group"] || ""),
          unread: params["unread"] in [true, "true", "1"],
          after: after_key,
          limit: limit(params["limit"])
        )

      next = if more?, do: rows |> List.last() |> encode()
      {:ok, %{items: Enum.map(rows, &item(&1, Scope.customer?(scope))), next_cursor: next}}
    end
  end

  @doc "`GET /notifications/count`: `%{unread}`."
  @spec count(Scope.t()) :: {:ok, map()} | {:error, term()}
  def count(%Scope{} = scope) do
    with {:ok, user_id} <- me(scope), do: {:ok, %{unread: Notifications.unread_count(user_id)}}
  end

  @doc "`GET /notifications/groups`: the groups with rows for this person, `[%{key, label}]`."
  @spec groups(Scope.t()) :: {:ok, [map()]} | {:error, term()}
  def groups(%Scope{} = scope) do
    with {:ok, user_id} <- me(scope),
         do:
           {:ok,
            Enum.map(Notifications.groups_with_rows(user_id), &%{key: &1.key, label: &1.label})}
  end

  @doc "`POST /notifications/:id/read`: one of the person's own; another's is not found."
  @spec read(Scope.t(), term(), DateTime.t()) :: :ok | {:error, term()}
  def read(%Scope{} = scope, id, %DateTime{} = now) do
    with {:ok, user_id} <- me(scope),
         %{} <- Notifications.mark_read(user_id, id, now) || {:error, :not_found} do
      tell(user_id)
    end
  end

  @doc "`POST /notifications/read-all`."
  @spec read_all(Scope.t(), DateTime.t()) :: :ok | {:error, term()}
  def read_all(%Scope{} = scope, %DateTime{} = now) do
    with {:ok, user_id} <- me(scope) do
      _count = Notifications.mark_all_read(user_id, now)
      tell(user_id)
    end
  end

  defp tell(user_id) do
    Realtime.send_all([Realtime.to_user(user_id, "notifications_read", %{})])
    :ok
  end

  @doc """
  One row as the bell shows it (§7.6). The customer reads a staff actor by
  first name, as everywhere in the portal (PLAN §3.4); a row whose team
  hides names carries no actor at all (`Core.Tasks.Notices`).
  """
  @spec item(map(), boolean()) :: map()
  def item(n, customer? \\ false) do
    %{
      id: n.id,
      kind: n.notification_kind_key,
      group: n.notification_kind.notification_group_key,
      title: n.title,
      body: n.body,
      link_path: n.link_path,
      actor: actor(n.actor_user, customer?),
      task_id: n.task_id,
      lead_id: n.lead_id,
      approval_id: n.approval_id,
      read_at: n.read_at,
      inserted_at: n.inserted_at
    }
  end

  defp actor(nil, _customer?), do: nil

  defp actor(%{person: person}, customer?) do
    photo = Person.photo_media_id(person)
    name = if customer?, do: Words.first_name(person), else: person.display_name
    %{name: name, photo_url: photo && Media.link(photo)}
  end

  defp me(scope) do
    case Scope.user_id(scope) do
      nil -> {:error, :not_found}
      id -> {:ok, id}
    end
  end

  # The cursor is the last row's `{inserted_at, id}`, opaque to the client.
  defp encode(row) do
    Base.url_encode64("#{DateTime.to_iso8601(row.inserted_at)}|#{row.id}", padding: false)
  end

  defp cursor(nil), do: {:ok, nil}
  defp cursor(""), do: {:ok, nil}

  defp cursor(value) when is_binary(value) do
    with {:ok, decoded} <- Base.url_decode64(value, padding: false),
         [at, id] <- String.split(decoded, "|"),
         {:ok, at, _offset} <- DateTime.from_iso8601(at),
         {:ok, id} <- Ecto.UUID.cast(id) do
      {:ok, {at, id}}
    else
      _bad -> {:error, {:invalid, %{"cursor" => ["is not a cursor this API gave"]}}}
    end
  end

  defp cursor(_other), do: {:error, {:invalid, %{"cursor" => ["is not a cursor this API gave"]}}}

  defp limit(value) do
    case Integer.parse(to_string(value || "")) do
      {n, ""} when n in 1..100 -> n
      _default -> @default_limit
    end
  end
end
