defmodule Core.Tasks do
  @moduledoc """
  The board (AQ-02 P2.1): a task read, made, edited, archived, deleted. The
  verbs that move a task are `Core.Tasks.Act`; its parts `People`,
  `Checklist`, `Steps`, `Links`, `Files`, `Comments`; its log `Histories`;
  the page `Board`; the customer's side `Portal`; due reminders `Due`.

  Every function takes a `%Data.Scope{}` first and asks `Core.Access`
  (`{:task, task}`, decided by `Core.Access.Tasks`); a task the caller may
  not see is `:not_found`, never `:forbidden`. Every write is one
  transaction (`Core.Tasks.Write`) holding the change, its history, its
  notifications and — QP2-11 — an audit row only for create, archive,
  unarchive, delete and changes to `customer_access`. Every task is in one
  team (AQ-03B §4), named at creation and never moved (QT-12); who of the
  team sees it is the team's `peer_tasks`, so there is no `is_private`.
  """

  alias Core.Access
  alias Core.Audit
  alias Core.Leads.TaskLinks
  alias Core.Realtime
  alias Core.Tasks.{Cards, Histories, Notices, Visibility, Words, Write}
  alias Data.Customers
  alias Data.Profiles
  alias Data.Scope
  alias Data.TaskParts
  alias Data.Tasks, as: Store
  alias Data.Tasks.Task
  alias Data.Teams

  @audited ~w(title state team_id customer_id profile_id customer_access archived_at)a
  @gone_words "is gone: who sees a task is its team's setting"
  @no_customer_words "This task isn't about a customer."

  # ── Reads ───────────────────────────────────────────────────────────────────

  @doc "The task behind `id`, if the caller may take `action` on it."
  @spec fetch(Scope.t(), atom(), term()) :: {:ok, Task.t()} | {:error, term()}
  def fetch(%Scope{} = scope, action, id) do
    with %Task{} = task <- Store.get(Scope.organisation_id(scope), id) || {:error, :not_found},
         :ok <- Access.why_not(scope, action, {:task, task}),
         do: {:ok, task}
  end

  @doc "`GET /tasks/:id`: the sheet — the console's, or the portal's for the customer."
  @spec get(Scope.t(), term(), DateTime.t()) :: {:ok, map()} | {:error, term()}
  def get(%Scope{} = scope, id, %DateTime{} = now) do
    with {:ok, task} <- fetch(scope, :read, id), do: {:ok, sheet(scope, task, now)}
  end

  @doc """
  The sheet of a task just written, as the caller now sees it; `:gone` when
  the write took it out of their sight (an assignee taking themselves off).
  """
  @spec answer(Scope.t(), {:ok, Task.t()} | {:error, term()}, DateTime.t()) ::
          {:ok, map() | :gone} | {:error, term()}
  def answer(%Scope{} = scope, {:ok, %Task{} = task}, %DateTime{} = now) do
    case fetch(scope, :read, task.id) do
      {:ok, fresh} -> {:ok, sheet(scope, fresh, now)}
      {:error, :not_found} -> {:ok, :gone}
    end
  end

  def answer(_scope, {:error, _reason} = error, _now), do: error

  defp sheet(scope, task, now) do
    if Scope.customer?(scope),
      do: Cards.portal_sheet(scope, task, now),
      else: Cards.sheet(scope, task, now)
  end

  @doc "`GET /tasks/:id/history`: the change groups, newest first (the customer's are §6.4's)."
  @spec history(Scope.t(), term()) :: {:ok, [map()]} | {:error, term()}
  def history(%Scope{} = scope, id) do
    with {:ok, task} <- fetch(scope, :read, id), do: {:ok, Histories.list(scope, task)}
  end

  @doc "`GET /tasks/search?q`: the relation picker — live tasks the caller sees, `[{id, title, state}]`."
  @spec search(Scope.t(), String.t() | nil) :: {:ok, [map()]} | {:error, term()}
  def search(%Scope{} = scope, q) do
    if Scope.staff?(scope),
      do:
        {:ok,
         scope
         |> Visibility.filter()
         |> Store.search(q)
         |> Enum.map(&%{id: &1.id, title: &1.title, state: &1.state})},
      else: {:error, :not_found}
  end

  # ── Create ──────────────────────────────────────────────────────────────────

  @doc """
  `POST /tasks {title, description?, state: todo|draft, team_id, customer_id?,
  profile_id?, customer_access?, priority?, due_at?|due_on?, reminder_minutes?,
  primary_user_id?, secondary_user_ids?, checklist?, steps?, lead_id?}`: `team_id` is
  required (422 without it) and a team the caller is in, or any for an admin
  (404 otherwise); the customer only one that team serves; `is_private` is
  gone (422 if sent, AQ-03B §5.1). With `lead_id` (AQ-04B §8.1) the task is on
  that lead — in its team, about its customer and profile — and writes
  `task_created` on it (`Core.Leads.TaskLinks`). Answers the sheet.
  """
  @spec create(Scope.t(), map(), DateTime.t()) :: {:ok, map() | :gone} | {:error, term()}
  def create(%Scope{} = scope, params, %DateTime{} = now) do
    params = stringify(params)

    with :ok <- no_private(params),
         {:ok, team_id} <- required_team(params),
         :ok <- Access.why_not(scope, :create, {:task, %{team_id: team_id}}),
         {:ok, team_id} <- team(scope, team_id),
         {:ok, link} <- TaskLinks.for_new_task(scope, team_id, params),
         params = Map.merge(params, link || %{}),
         {:ok, customer_id, profile_id} <- about(scope, team_id, params),
         {:ok, state} <- new_state(params["state"]),
         {:ok, primary, secondary} <- assignees(scope, team_id, params),
         {:ok, steps} <- new_steps(scope, team_id, customer_id, params["steps"]) do
      attrs =
        params
        |> editable()
        |> Map.merge(%{
          "organisation_id" => Scope.organisation_id(scope),
          "author_user_id" => Scope.user_id(scope),
          "source" => "staff",
          "state" => state,
          "team_id" => team_id,
          "customer_id" => customer_id,
          "profile_id" => profile_id,
          "lead_id" => link && link["lead_id"]
        })

      scope
      |> answer(
        Write.commit(fn ->
          insert(scope, attrs, {primary, secondary}, list(params["checklist"]), steps, now)
        end),
        now
      )
    end
  end

  @doc false
  # The insert every creator shares (the portal's too): the row, its people,
  # its parts, the *created* line, the audit row, and who is told.
  def insert(scope, attrs, {primary, secondary}, checklist, steps, now, opts \\ []) do
    with {:ok, task} <- Store.create(attrs) do
      :ok = Store.put_assignees(task, primary, secondary)
      Enum.each(checklist, &Write.ok!(TaskParts.add_item(task.id, &1)))
      Enum.each(steps, &Write.ok!(TaskParts.add_step(task.id, &1)))
      task = Store.reload(task)
      group = Histories.group_id()

      created = Histories.line(:created, nil, task.state, nil, Words.state(task.state))
      :ok = Histories.write(scope, task.id, group, [created], now)
      {:ok, _event} = Audit.record(scope, "created", task, after: snapshot(task), now: now)

      told = Keyword.get(opts, :told) || fn task -> Notices.became_real(scope, task, group) end
      linked = TaskLinks.created(scope, task, now)
      {:ok, task, [told.(task), linked, Realtime.task_events("task_created", nil, task)]}
    end
  end

  # ── Edit ────────────────────────────────────────────────────────────────────

  @doc """
  `PATCH /tasks/:id`: title, description, priority, due, reminder, customer,
  profile, customer access — one history group. Who the customer sees it as
  (`customer_access`) is the author's or a lead's. The team stays (QT-12): a
  different `team_id` is a field error, and so is `is_private`.
  """
  @spec update(Scope.t(), term(), map(), DateTime.t()) :: {:ok, map() | :gone} | {:error, term()}
  def update(%Scope{} = scope, id, params, %DateTime{} = now) do
    params = stringify(params)

    with {:ok, task} <- fetch(scope, :edit, id),
         :ok <- no_private(params),
         :ok <- same_team(task, params),
         attrs = editable(params),
         :ok <- may_change_who_sees(scope, task, attrs),
         team_id = task.team_id,
         merged = Map.merge(current(task), attrs),
         {:ok, customer_id, profile_id} <-
           about_if_moved(scope, task, team_id, follow_customer(task, merged)),
         attrs =
           Map.merge(attrs, %{
             "customer_id" => customer_id,
             "profile_id" => profile_id
           }),
         attrs = if(customer_id, do: attrs, else: Map.put(attrs, "customer_access", "none")),
         :ok <- customer_steps_kept(task, customer_id) do
      answer(scope, Write.commit(fn -> save(scope, task, attrs, now) end), now)
    end
  end

  @doc false
  # An edit, logged as one group; audited when who sees it changed (QP2-11);
  # the customer told when the task is now theirs to do.
  def save(scope, task, attrs, now) do
    with {:ok, updated} <- Store.update(task, attrs) do
      group = Histories.group_id()
      lines = Histories.diff(task, updated, zone(scope))
      :ok = Histories.write(scope, task.id, group, lines, now)

      if Enum.any?(lines, &(&1.field == :customer_access)) do
        {:ok, _event} =
          Audit.record(scope, "visibility_changed", updated,
            before: snapshot(task),
            after: snapshot(updated),
            now: now
          )
      end

      told =
        if updated.customer_access == :assigned and task.customer_access != :assigned,
          do: Notices.assigned_customer(scope, updated, group),
          else: []

      {:ok, updated, [told, Realtime.task_events("task_updated", task, updated)]}
    end
  end

  defp may_change_who_sees(scope, task, attrs) do
    changes? =
      Map.has_key?(attrs, "customer_access") and
        to_string(attrs["customer_access"]) != to_string(task.customer_access)

    if changes?, do: Access.why_not(scope, :change_visibility, {:task, task}), else: :ok
  end

  # AQ-03B §5.1: `is_private` is gone, and saying it is a field error.
  defp no_private(params) do
    if Map.has_key?(params, "is_private"),
      do: {:error, {:invalid, %{"is_private" => [@gone_words]}}},
      else: :ok
  end

  defp required_team(params) do
    case blank(params["team_id"]) do
      nil -> {:error, {:invalid, %{"team_id" => ["is required"]}}}
      team_id -> {:ok, team_id}
    end
  end

  # QT-12: a task stays in its team; sending the same team is harmless.
  defp same_team(task, %{"team_id" => team_id}) do
    if blank(team_id) == task.team_id,
      do: :ok,
      else: {:error, {:invalid, %{"team_id" => ["can't be moved to another team"]}}}
  end

  defp same_team(_task, _params), do: :ok

  # What a task is about is checked again only when it moves: a customer
  # since taken off the team does not freeze the task's title.
  defp about_if_moved(scope, task, team_id, merged) do
    if {team_id, merged["customer_id"], merged["profile_id"]} ==
         {task.team_id, task.customer_id, task.profile_id},
       do: {:ok, task.customer_id, task.profile_id},
       else: about(scope, team_id, merged)
  end

  # A new customer without a profile named drops the old customer's profile.
  defp follow_customer(task, merged) do
    if merged["customer_id"] != task.customer_id and merged["profile_id"] == task.profile_id,
      do: Map.put(merged, "profile_id", nil),
      else: merged
  end

  defp customer_steps_kept(%{customer_id: same}, same), do: :ok

  defp customer_steps_kept(task, _other) do
    if Enum.any?(task.steps, & &1.is_for_customer),
      do:
        {:error,
         {:invalid, %{"customer_id" => ["has steps for the customer; remove them first"]}}},
      else: :ok
  end

  # ── What a task may be about, and who may be on it ─────────────────────────

  @doc false
  # A live team of the organisation the caller is in (any, for an admin).
  def team(%Scope{} = scope, team_id) do
    with %{archived_at: nil} = team <- Teams.get(Scope.organisation_id(scope), team_id),
         true <- Scope.admin?(scope) or not is_nil(Scope.team_role(scope, team.id)) do
      {:ok, team.id}
    else
      _other -> {:error, :not_found}
    end
  end

  # The customer: one the caller may read, served by the team when there is
  # one; the profile: one of that customer's live ones.
  defp about(scope, team_id, params) do
    with {:ok, customer} <- customer(scope, blank(params["customer_id"]), team_id),
         {:ok, profile_id} <- profile(customer, blank(params["profile_id"])) do
      {:ok, customer && customer.id, profile_id}
    end
  end

  defp customer(_scope, nil, _team_id), do: {:ok, nil}

  defp customer(scope, id, team_id) do
    with %{} = customer <- Customers.get(Scope.organisation_id(scope), id) || {:error, :not_found},
         :ok <- Access.why_not(scope, :read, {:customer, customer}) do
      if is_nil(team_id) or team_id in customer.team_ids,
        do: {:ok, customer},
        else: {:error, {:invalid, %{"customer_id" => ["is not a customer of this team"]}}}
    end
  end

  defp profile(_customer, nil), do: {:ok, nil}
  defp profile(nil, _id), do: {:error, {:invalid, %{"profile_id" => ["needs a customer"]}}}

  defp profile(customer, id) do
    case Profiles.get(id) do
      %{customer_id: cid, archived_at: nil} = p when cid == customer.id ->
        {:ok, p.id}

      _other ->
        {:error, {:invalid, %{"profile_id" => ["is not one of this customer's profiles"]}}}
    end
  end

  @doc false
  # The staff who may be given work on a task of `team_id`: its open members.
  # Anyone else is not found.
  def staff_for(%Scope{}, team_id) do
    team_id |> Teams.list_members() |> Enum.map(& &1.user_id) |> Enum.uniq()
  end

  @doc false
  def assignees(scope, team_id, params) do
    primary = blank(params["primary_user_id"])
    secondary = (list(params["secondary_user_ids"]) -- [primary]) |> Enum.uniq()
    staff = staff_for(scope, team_id)

    if Enum.all?(List.wrap(primary) ++ secondary, &(&1 in staff)),
      do: {:ok, primary, secondary},
      else: {:error, :not_found}
  end

  defp new_steps(scope, team_id, customer_id, steps) do
    staff = staff_for(scope, team_id)

    Enum.reduce_while(list(steps), {:ok, []}, fn step, {:ok, acc} ->
      step = stringify(step)

      case step_attrs(step, staff, customer_id) do
        {:ok, attrs} -> {:cont, {:ok, acc ++ [attrs]}}
        error -> {:halt, error}
      end
    end)
  end

  @doc false
  def step_attrs(step, staff, customer_id) do
    for_customer = step["is_for_customer"] in [true, "true"]
    assignee = blank(step["assignee_user_id"])

    cond do
      for_customer and is_nil(customer_id) ->
        {:error, {:forbidden, @no_customer_words}}

      assignee && assignee not in staff ->
        {:error, :not_found}

      true ->
        {:ok, %{title: step["title"], assignee_user_id: assignee, is_for_customer: for_customer}}
    end
  end

  defp new_state(nil), do: {:ok, "todo"}
  defp new_state(state) when state in ["todo", "draft"], do: {:ok, state}
  defp new_state(_other), do: {:error, {:invalid, %{"state" => ["is To do or a draft"]}}}

  # ── Helpers ─────────────────────────────────────────────────────────────────

  # What `PATCH` may set, with `normal` meaning no priority and one due
  # replacing the other; a reminder goes with its due time.
  defp editable(params) do
    attrs = Map.take(params, Enum.map(Task.editable_fields(), &to_string/1))

    attrs
    |> then(&if(&1["priority"] == "normal", do: Map.put(&1, "priority", nil), else: &1))
    |> then(
      &if(blank(&1["due_at"]) && Map.has_key?(attrs, "due_at"),
        do: Map.put(&1, "due_on", nil),
        else: &1
      )
    )
    |> then(
      &if(blank(&1["due_on"]) && Map.has_key?(attrs, "due_on"),
        do: Map.put(&1, "due_at", nil),
        else: &1
      )
    )
    |> then(
      &if(Map.has_key?(&1, "due_at") and is_nil(blank(&1["due_at"])),
        do: Map.put(&1, "reminder_minutes", nil),
        else: &1
      )
    )
  end

  defp current(task) do
    Map.new(Task.editable_fields(), &{to_string(&1), Map.get(task, &1)})
  end

  @doc false
  def zone(%Scope{organisation: %{timezone: zone}}) when is_binary(zone), do: zone
  def zone(_scope), do: "Etc/UTC"

  @doc false
  def snapshot(task), do: Audit.snapshot(task, @audited)

  @doc false
  def stringify(params) when is_map(params),
    do: Map.new(params, fn {k, v} -> {to_string(k), v} end)

  def stringify(_params), do: %{}

  @doc false
  def blank(value) when is_binary(value), do: Utils.presence(value)
  def blank(value), do: value

  defp list(values) when is_list(values), do: values
  defp list(_none), do: []
end
