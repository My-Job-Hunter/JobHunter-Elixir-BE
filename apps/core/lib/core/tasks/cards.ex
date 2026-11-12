defmodule Core.Tasks.Cards do
  @moduledoc """
  The board's read models (AQ-02 §7.6): **the card**, **the step card**,
  **the sheet**, and the portal's own card and sheet. Built here, in the
  context, because what a card says depends on who reads it — `mine`,
  `can_move`, `overdue` in the reader's zone, the comment count the
  customer may see, first names or "The team" — and field-level
  restriction is the context's (PLAN §3.5). `ApiShared.TasksJSON` lists the
  fields out; the portal's builders never compute a staff field at all.

  `context/3` reads what a set of cards needs once (the reader's zone, the
  counts); `card/2` and `portal_card/2` are then plain functions of it.
  """

  alias Core.Access
  alias Core.Media
  alias Core.Tasks.{Histories, Person, Words}
  alias Data.Accounts
  alias Data.Scope
  alias Data.Tasks, as: Store

  @open [:todo, :in_progress, :on_hold]

  @doc "What building cards for `tasks` needs: the reader, the moment, their zone, the counts."
  @spec context(Scope.t(), [map()], DateTime.t()) :: map()
  def context(%Scope{} = scope, tasks, %DateTime{} = now) do
    ids = Enum.map(tasks, & &1.id)
    zone = zone(scope)

    %{
      scope: scope,
      me: Scope.user_id(scope),
      customer?: Scope.customer?(scope),
      now: now,
      zone: zone,
      today: today(now, zone),
      comments: Store.comment_counts(ids, staff_only: not Scope.customer?(scope)),
      files: Store.file_counts(ids)
    }
  end

  defp zone(scope) do
    case Scope.user_id(scope) && Accounts.get_user(Scope.user_id(scope)) do
      %{person: %{timezone: zone}} when is_binary(zone) -> zone
      _nobody -> "Etc/UTC"
    end
  end

  defp today(now, zone) do
    case DateTime.shift_zone(now, zone) do
      {:ok, local} -> DateTime.to_date(local)
      _unknown -> DateTime.to_date(now)
    end
  end

  # ── The card ────────────────────────────────────────────────────────────────

  @doc "The console's card."
  @spec card(map(), map()) :: map()
  def card(ctx, task) do
    assignees = assignees(task)

    %{
      kind: "task",
      id: task.id,
      title: task.title,
      state: task.state,
      stage: task.stage && %{id: task.stage.id, name: task.stage.name},
      priority: task.priority,
      due_at: task.due_at,
      due_on: task.due_on,
      overdue: overdue?(task, ctx),
      team: task.team && %{id: task.team.id, name: task.team.name},
      customer:
        task.customer && %{id: task.customer.id, display_name: task.customer.display_name},
      profile: task.profile && %{id: task.profile.id, title: task.profile.title},
      customer_access: task.customer_access,
      source: task.source,
      people:
        Enum.map(assignees, fn p ->
          p.user |> Person.view() |> Map.merge(%{level: p.level, me: p.user_id == ctx.me})
        end),
      needs_owner: needs_owner?(task),
      progress: progress(task, &(&1.assignee_user_id == ctx.me)),
      comment_count: Map.get(ctx.comments, task.id, 0),
      file_count: Map.get(ctx.files, task.id, 0),
      hold: task.state == :on_hold && %{reason: task.hold_reason, at: task.held_at},
      closed:
        task.state == :closed &&
          %{reason: task.closed_reason, note: task.closed_note, at: task.closed_at},
      done_at: task.done_at,
      mine: mine?(task, ctx.me),
      can_move: Access.can?(ctx.scope, :move, {:task, task}),
      updated_at: task.updated_at
    }
    |> Map.update!(:hold, &(&1 || nil))
    |> Map.update!(:closed, &(&1 || nil))
  end

  @doc "A step of mine on somebody else's task, in its task's column (§7.2)."
  @spec step_card(map(), map(), map()) :: map()
  def step_card(ctx, task, step) do
    steps = task.steps

    %{
      kind: "step",
      step: %{
        id: step.id,
        title: step.title,
        position: Enum.find_index(steps, &(&1.id == step.id)) + 1,
        total: length(steps)
      },
      task: card(ctx, task)
    }
  end

  @doc "On My board: assigned to me, or mine and nobody else's (QP2-16)."
  @spec mine?(map(), binary()) :: boolean()
  def mine?(task, me) do
    Enum.any?(task.participants, &(&1.user_id == me and &1.level)) or
      (task.author_user_id == me and not Enum.any?(task.participants, & &1.level))
  end

  @doc "A team's task nobody is on, still open: *needs an owner*."
  @spec needs_owner?(map()) :: boolean()
  def needs_owner?(task) do
    task.state in @open and
      not Enum.any?(task.participants, & &1.level)
  end

  @doc "Open and past its due in the reader's day."
  @spec overdue?(map(), map()) :: boolean()
  def overdue?(task, %{now: now, today: today}) do
    task.state in @open and
      ((task.due_at && DateTime.compare(task.due_at, now) == :lt) ||
         (task.due_on && Date.compare(task.due_on, today) == :lt) || false)
  end

  # Primary first, then the rest by name.
  defp assignees(task) do
    task.participants
    |> Enum.filter(& &1.level)
    |> Enum.sort_by(&{&1.level != :primary, &1.user.person.display_name})
  end

  defp progress(task, mine?) do
    items = task.checklist_items
    steps = task.steps

    %{
      checklist: items != [] && %{done: Enum.count(items, & &1.checked_at), total: length(items)},
      steps:
        steps != [] &&
          %{
            done: Enum.count(steps, & &1.done_at),
            total: length(steps),
            mine: Enum.count(steps, &(is_nil(&1.done_at) and mine?.(&1)))
          }
    }
    |> Map.new(fn {k, v} -> {k, v || nil} end)
  end

  # ── The portal's card ───────────────────────────────────────────────────────

  @doc "The portal's card: no team, stage, priority or hold reason; first names or \"The team\"."
  @spec portal_card(map(), map()) :: map()
  def portal_card(ctx, task) do
    names? = Histories.names?(task)
    firsts = task |> assignees() |> Enum.map(&Person.first_name(&1.user))

    %{
      id: task.id,
      title: task.title,
      state: task.state,
      due_at: task.due_at,
      due_on: task.due_on,
      overdue: overdue?(task, ctx),
      profile: task.profile && %{id: task.profile.id, title: task.profile.title},
      source: task.source,
      customer_access: task.customer_access,
      people:
        if(names?,
          do:
            Enum.map(
              assignees(task),
              &%{name: Person.first_name(&1.user), photo_url: Person.photo_url(&1.user.person)}
            ),
          else: []
        ),
      on_it: Words.on_it(firsts, names?),
      progress: progress(task, & &1.is_for_customer),
      comment_count: Map.get(ctx.comments, task.id, 0),
      file_count: Map.get(ctx.files, task.id, 0),
      done_at: task.done_at,
      closed: if(task.state == :closed, do: %{reason: task.closed_reason, at: task.closed_at}),
      yours_to_do: yours_to_do?(task),
      made_by_you: task.source == :customer,
      updated_at: task.updated_at
    }
  end

  @doc "Waiting on the customer: given to them, or a step of theirs still open."
  @spec yours_to_do?(map()) :: boolean()
  def yours_to_do?(task) do
    task.customer_access == :assigned or
      Enum.any?(task.steps, &(&1.is_for_customer and is_nil(&1.done_at)))
  end

  # ── The sheets ──────────────────────────────────────────────────────────────

  @doc "`GET /tasks/:id` for staff: the card and everything the sheet shows."
  @spec sheet(Scope.t(), map(), DateTime.t()) :: map()
  def sheet(%Scope{} = scope, task, %DateTime{} = now) do
    task = Store.sheet(task)
    ctx = context(scope, [task], now)
    me = ctx.me
    view = &Person.view(&1, customer: task.customer)
    my_row = Enum.find(task.participants, &(&1.user_id == me))
    can = &Access.can?(scope, &1, {:task, task})

    ctx
    |> card(task)
    |> Map.merge(%{
      description: task.description,
      reminder_minutes: task.reminder_minutes,
      author: view.(task.author_user),
      inserted_at: task.inserted_at,
      held_from_state: task.held_from_state,
      checklist:
        Enum.map(task.checklist_items, fn i ->
          %{
            id: i.id,
            text: i.text,
            position: i.position,
            checked_at: i.checked_at,
            checked_by: view.(i.checked_by_user)
          }
        end),
      steps:
        Enum.map(task.steps, fn s ->
          %{
            id: s.id,
            title: s.title,
            position: s.position,
            assignee: view.(s.assignee_user),
            is_for_customer: s.is_for_customer,
            done_at: s.done_at,
            done_by: view.(s.done_by_user),
            mine: s.assignee_user_id == me
          }
        end),
      links: Enum.map(task.links, &link/1),
      relations: relations(scope, task),
      files: Enum.map(task.task_media, &Map.put(file(&1), :added_by, view.(&1.added_by_user))),
      watchers: for(p <- task.participants, p.is_watcher, do: Person.view(p.user)),
      me_on: %{watching: !!(my_row && my_row.is_watcher), muted: !!(my_row && my_row.is_muted)},
      can: %{
        edit: can.(:edit),
        move: can.(:move),
        comment_staff_only: can.(:comment_staff_only),
        delete: can.(:delete),
        change_visibility: can.(:change_visibility),
        share: can.(:read)
      },
      customer_sees: task.customer_access != :none
    })
  end

  @doc "`GET /tasks/:id` for the customer: the portal card and the parts they may see."
  @spec portal_sheet(Scope.t(), map(), DateTime.t()) :: map()
  def portal_sheet(%Scope{} = scope, task, %DateTime{} = now) do
    task = Store.sheet(task)
    ctx = context(scope, [task], now)
    names? = Histories.names?(task)
    open? = task.state in @open
    can = &Access.can?(scope, &1, {:task, task})

    ctx
    |> portal_card(task)
    |> Map.merge(%{
      description: task.description,
      checklist:
        Enum.map(
          task.checklist_items,
          &%{id: &1.id, text: &1.text, position: &1.position, checked_at: &1.checked_at}
        ),
      steps:
        Enum.map(task.steps, fn s ->
          %{
            id: s.id,
            title: s.title,
            position: s.position,
            done_at: s.done_at,
            yours: s.is_for_customer,
            on_it: step_on_it(s, names?)
          }
        end),
      links: Enum.map(task.links, &link/1),
      files: Enum.map(task.task_media, &file/1),
      can: %{
        done: can.(:complete) and open?,
        reopen: can.(:complete) and task.state == :done,
        withdraw: can.(:withdraw) and open?,
        edit: can.(:edit_own),
        tick: can.(:tick) and task.state != :closed,
        comment: can.(:comment),
        add_file: can.(:files)
      }
    })
  end

  defp step_on_it(%{is_for_customer: true}, _names?), do: nil
  defp step_on_it(%{assignee_user: nil}, _names?), do: nil
  defp step_on_it(_step, false), do: "The team"
  defp step_on_it(step, true), do: Person.first_name(step.assignee_user)

  defp link(l), do: %{id: l.id, url: l.url, label: l.label, position: l.position}

  defp file(%{media: m} = link) do
    %{
      id: m.id,
      url: Media.link(m.id),
      byte_count: m.byte_count,
      content_type: m.content_type,
      original_filename: m.original_filename,
      inserted_at: link.inserted_at
    }
  end

  # Only the ends the reader may see: a relation never names a task they cannot open.
  defp relations(scope, task) do
    for r <- Store.relations(task.id),
        {direction, other} =
          if(r.from_task_id == task.id,
            do: {"outgoing", r.to_task},
            else: {"incoming", r.from_task}
          ),
        Access.can?(scope, :read, {:task, other}) do
      %{
        id: r.id,
        kind: r.kind,
        direction: direction,
        task: %{id: other.id, title: other.title, state: other.state}
      }
    end
  end
end
