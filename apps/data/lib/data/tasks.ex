defmodule Data.Tasks do
  @moduledoc """
  Tasks and their participants (AQ-02 §5.1); every task is in one team
  (AQ-03B §4). Storage only: who sees a task
  is `Core.Tasks.Visibility`'s decision, handed here as a plain map and
  composed into **every** read by `visible/2`; what a verb may do is
  `Core.Access`'s and `Core.Tasks.Act`'s. The parts of a task are
  `Data.TaskParts`, its thread `Data.TaskComments`, its log
  `Data.TaskHistories`, a person's stages `Data.TaskStages`.

  Every task read here comes with `participants`, `steps` and `customer`, because
  `Core.Access` decides from them and a decision should not depend on what
  happens to be loaded.
  """

  import Ecto.Query, warn: false

  alias Data.Repo
  alias Data.Tasks.{Comment, Participant, Relation, Reply, Step, Task, TaskMedia}

  @person [person: :photo]
  @access [:participants, :steps, :customer]
  @card [
    :team,
    :customer,
    :profile,
    :stage,
    :checklist_items,
    author_user: @person,
    participants: [user: @person],
    steps: [assignee_user: @person]
  ]
  @sheet @card ++
           [
             :links,
             checklist_items: [checked_by_user: @person],
             steps: [assignee_user: @person, done_by_user: @person],
             task_media: [:media, added_by_user: @person]
           ]

  # ── Visibility ──────────────────────────────────────────────────────────────

  @doc """
  §6.1 as a query (AQ-03B §3.2). `filter` is `Core.Tasks.Visibility`'s map:
  for staff `%{organisation_id, user_id, admin?, lead_team_ids,
  peer_team_ids}` (`peer_team_ids`: the teams where the caller is a member
  and `peer_tasks` is `view` or `edit`), for the customer
  `%{organisation_id, customer_id}`. A draft is its author's alone;
  everyone else's rules start at To do.
  """
  @spec visible(Ecto.Queryable.t(), map()) :: Ecto.Query.t()
  def visible(query, %{organisation_id: org_id, customer_id: customer_id})
      when is_binary(customer_id) do
    from(t in query,
      where:
        t.organisation_id == ^org_id and t.customer_id == ^customer_id and
          t.customer_access in [:shared, :assigned] and t.state != :draft and
          is_nil(t.archived_at)
    )
  end

  def visible(query, %{organisation_id: org_id, user_id: me} = filter) do
    rules =
      dynamic([t], t.author_user_id == ^me or (t.state != :draft and ^beyond_drafts(filter)))

    from(t in query, where: t.organisation_id == ^org_id, where: ^rules)
  end

  # Rules 1 and 2 of §6.1, once a task is To do or later.
  defp beyond_drafts(%{user_id: me} = filter) do
    on_it =
      from(p in Participant,
        where: p.user_id == ^me and (not is_nil(p.level) or p.is_watcher),
        select: p.task_id
      )

    my_steps = from(s in Step, where: s.assignee_user_id == ^me, select: s.task_id)

    dynamic(
      [t],
      t.id in subquery(on_it) or t.id in subquery(my_steps) or
        t.team_id in ^filter.lead_team_ids or t.team_id in ^filter.peer_team_ids or
        ^filter.admin?
    )
  end

  # ── Reads ───────────────────────────────────────────────────────────────────

  @doc "A task of the organisation with its participants and steps; `nil` for a malformed or foreign id."
  @spec get(binary(), term()) :: Task.t() | nil
  def get(organisation_id, id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} ->
        Task |> Repo.get_by(id: uuid, organisation_id: organisation_id) |> load(@access)

      :error ->
        nil
    end
  end

  @doc "The task with everything the sheet shows (relations are `relations/1`)."
  @spec sheet(Task.t()) :: Task.t()
  def sheet(%Task{} = task), do: Repo.preload(task, @sheet, force: true)

  @doc """
  The tasks `filter` sees, with what a card shows. Options: `view`, a list
  of narrowings that all apply (`{:team, team_id}`, `{:mine, user_id}`,
  `{:watching, user_id}`, `{:customer, customer_id}`; `:all` or `[]` for
  none), `archived` (only the archived when true; never them otherwise).
  """
  @spec list(map(), keyword()) :: [Task.t()]
  def list(filter, opts \\ []) do
    Task
    |> visible(filter)
    |> view(Keyword.get(opts, :view, :all))
    |> archived(Keyword.get(opts, :archived, false))
    |> order_by([t], asc: t.inserted_at, asc: t.id)
    |> preload(^@card)
    |> Repo.all()
  end

  defp view(query, :all), do: query
  defp view(query, views) when is_list(views), do: Enum.reduce(views, query, &view(&2, &1))
  defp view(query, {:team, team_id}), do: where(query, [t], t.team_id == ^team_id)
  defp view(query, {:customer, id}), do: where(query, [t], t.customer_id == ^id)

  defp view(query, {:watching, me}) do
    watched = from(p in Participant, where: p.user_id == ^me and p.is_watcher, select: p.task_id)
    where(query, [t], t.id in subquery(watched))
  end

  # Mine (QP2-16): assigned to me, my open steps, and what I wrote — the
  # context keeps my own only when nobody else is on it.
  defp view(query, {:mine, me}) do
    assigned =
      from(p in Participant, where: p.user_id == ^me and not is_nil(p.level), select: p.task_id)

    steps =
      from(s in Step,
        where: s.assignee_user_id == ^me and is_nil(s.done_at),
        select: s.task_id
      )

    where(
      query,
      [t],
      t.author_user_id == ^me or t.id in subquery(assigned) or t.id in subquery(steps)
    )
  end

  defp archived(query, true), do: where(query, [t], not is_nil(t.archived_at))
  defp archived(query, _live), do: where(query, [t], is_nil(t.archived_at))

  @doc "Up to 20 live tasks `filter` sees whose title matches `q`: the relation picker."
  @spec search(map(), String.t() | nil) :: [Task.t()]
  def search(filter, q) do
    like = "%" <> String.replace(q || "", ~r/[%_\\]/, "") <> "%"

    Task
    |> visible(filter)
    |> where([t], is_nil(t.archived_at) and ilike(t.title, ^like))
    |> order_by([t], desc: t.updated_at)
    |> limit(20)
    |> Repo.all()
  end

  @doc "Live comments and replies per task, as `%{task_id => n}`; `staff_only: false` counts what the customer reads."
  @spec comment_counts([binary()], keyword()) :: %{binary() => non_neg_integer()}
  def comment_counts([], _opts), do: %{}

  def comment_counts(task_ids, opts) do
    staff_only? = Keyword.get(opts, :staff_only, true)

    count = fn schema ->
      from(c in schema,
        where: c.task_id in ^task_ids and is_nil(c.deleted_at),
        group_by: c.task_id,
        select: {c.task_id, count(c.id)}
      )
      |> then(&if(staff_only?, do: &1, else: where(&1, [c], not c.is_staff_only)))
      |> Repo.all()
      |> Map.new()
    end

    Map.merge(count.(Comment), count.(Reply), fn _id, a, b -> a + b end)
  end

  @doc "Files per task, as `%{task_id => n}`."
  @spec file_counts([binary()]) :: %{binary() => non_neg_integer()}
  def file_counts([]), do: %{}

  def file_counts(task_ids) do
    from(m in TaskMedia,
      where: m.task_id in ^task_ids,
      group_by: m.task_id,
      select: {m.task_id, count(m.media_id)}
    )
    |> Repo.all()
    |> Map.new()
  end

  @doc "A task's relations from either end, each with the task at the other end."
  @spec relations(binary()) :: [Relation.t()]
  def relations(task_id) do
    from(r in Relation,
      where: r.from_task_id == ^task_id or r.to_task_id == ^task_id,
      order_by: [asc: r.inserted_at],
      preload: [from_task: ^@access, to_task: ^@access]
    )
    |> Repo.all()
  end

  @doc """
  Every open, live, non-draft task with a due, across organisations, with
  participants, steps and customer: the due scan's candidates. Unscoped on
  purpose (CONVENTIONS §2) — the scan acts for the system.
  """
  @spec list_due_for_system() :: [Task.t()]
  def list_due_for_system do
    from(t in Task,
      where:
        t.state in [:todo, :in_progress, :on_hold] and is_nil(t.archived_at) and
          (not is_nil(t.due_at) or not is_nil(t.due_on)),
      preload: ^[:organisation, :team, :customer, participants: [user: @person]]
    )
    |> Repo.all()
  end

  @doc """
  The open tasks linked to leads (AQ-04B §6.1: *Next*): not a draft, not
  done or closed, not archived — `%{lead_id => [task]}`, with no preloads.
  """
  @spec open_for_leads([binary()]) :: %{binary() => [Task.t()]}
  def open_for_leads([]), do: %{}

  def open_for_leads(lead_ids) do
    from(t in Task,
      where:
        t.lead_id in ^lead_ids and t.state in [:todo, :in_progress, :on_hold] and
          is_nil(t.archived_at)
    )
    |> Repo.all()
    |> Enum.group_by(& &1.lead_id)
  end

  @doc """
  The tasks linked to a lead that `filter` sees (AQ-04B §8.1 Tasks: staff by
  §6.1, the customer the ones shown to them), live ones, oldest first, with
  what a card shows.
  """
  @spec for_lead(map(), binary()) :: [Task.t()]
  def for_lead(filter, lead_id) do
    Task
    |> visible(filter)
    |> where([t], t.lead_id == ^lead_id and is_nil(t.archived_at))
    |> order_by([t], asc: t.inserted_at, asc: t.id)
    |> preload(^@card)
    |> Repo.all()
  end

  defp load(nil, _preloads), do: nil
  defp load(task, preloads), do: Repo.preload(task, preloads)

  @doc "The task again, with participants and steps fresh."
  @spec reload(Task.t()) :: Task.t()
  def reload(%Task{} = task), do: Task |> Repo.get!(task.id) |> load(@access)

  # ── Writes ──────────────────────────────────────────────────────────────────

  @spec create(map()) :: {:ok, Task.t()} | {:error, Ecto.Changeset.t()}
  def create(attrs) do
    with {:ok, task} <- %Task{} |> Task.changeset(attrs) |> Repo.insert(),
         do: {:ok, reload(task)}
  end

  @spec update(Task.t(), map()) :: {:ok, Task.t()} | {:error, Ecto.Changeset.t()}
  def update(%Task{} = task, attrs) do
    with {:ok, updated} <- task |> Task.changeset(attrs) |> Repo.update(),
         do: {:ok, reload(updated)}
  end

  @doc "A verb's move: the state and its columns."
  @spec move(Task.t(), map()) :: {:ok, Task.t()} | {:error, Ecto.Changeset.t()}
  def move(%Task{} = task, attrs) do
    with {:ok, moved} <- task |> Task.state_changeset(attrs) |> Repo.update(),
         do: {:ok, reload(moved)}
  end

  @spec archive(Task.t(), DateTime.t() | nil, binary() | nil) :: {:ok, Task.t()}
  def archive(%Task{} = task, at, user_id) do
    {:ok, updated} = task |> Task.archive_changeset(at, user_id) |> Repo.update()
    {:ok, reload(updated)}
  end

  @spec delete(Task.t()) :: {:ok, Task.t()} | {:error, Ecto.Changeset.t()}
  def delete(%Task{} = task), do: Repo.delete(task)

  # ── Participants ────────────────────────────────────────────────────────────

  @doc """
  The assignees become exactly `primary` and `secondary` (user ids); rows
  that only watch or mute keep that, and a row that says nothing goes.
  """
  @spec put_assignees(Task.t(), binary() | nil, [binary()]) :: :ok
  def put_assignees(%Task{} = task, primary, secondary) do
    wanted = Map.new(secondary, &{&1, :secondary})
    wanted = if primary, do: Map.put(wanted, primary, :primary), else: wanted
    rows = Repo.all(from(p in Participant, where: p.task_id == ^task.id))

    # The old primary steps down first, so the one-primary index never sees two.
    for %{level: :primary} = row <- rows, Map.get(wanted, row.user_id) != :primary do
      set_level(row, Map.get(wanted, row.user_id))
    end

    for row <- rows, Map.get(wanted, row.user_id) != :primary, row.level != :primary do
      set_level(row, Map.get(wanted, row.user_id))
    end

    for {user_id, level} <- wanted,
        level == :primary or not Enum.any?(rows, &(&1.user_id == user_id)) do
      upsert(task.id, user_id, level: level)
    end

    :ok
  end

  defp set_level(row, level) do
    if level || row.is_watcher || row.is_muted,
      do: row |> Ecto.Changeset.change(level: level) |> Repo.update!(),
      else: Repo.delete!(row)
  end

  @doc "Sets `is_watcher` or `is_muted` for one person, adding or dropping the row as needed."
  @spec put_flag(Task.t(), binary(), :is_watcher | :is_muted, boolean()) :: :ok
  def put_flag(%Task{} = task, user_id, flag, on?) when flag in [:is_watcher, :is_muted] do
    case Repo.get_by(Participant, task_id: task.id, user_id: user_id) do
      nil when on? -> upsert(task.id, user_id, [{flag, true}])
      nil -> :ok
      row -> row |> Ecto.Changeset.change([{flag, on?}]) |> keep_or_drop()
    end

    :ok
  end

  defp keep_or_drop(%Ecto.Changeset{} = changeset) do
    row = Ecto.Changeset.apply_changes(changeset)

    if row.level || row.is_watcher || row.is_muted,
      do: Repo.update!(changeset),
      else: Repo.delete!(changeset.data)
  end

  defp upsert(task_id, user_id, fields) do
    case Repo.get_by(Participant, task_id: task_id, user_id: user_id) do
      nil ->
        %Participant{}
        |> Participant.changeset(
          Map.merge(%{task_id: task_id, user_id: user_id}, Map.new(fields))
        )
        |> Repo.insert!()

      row ->
        row |> Ecto.Changeset.change(fields) |> Repo.update!()
    end
  end
end
