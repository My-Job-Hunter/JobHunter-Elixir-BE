defmodule Core.Tasks.Notices do
  @moduledoc """
  Who is told what about a task (AQ-02 §8), **inside the change's
  transaction**, each row ensured by its dedupe key
  (`Core.Notifications.ensure/2`, which plans the row's
  deliveries in the same transaction, AQ-08 §7.1) and its words **frozen in the recipient's
  terms**: staff read the actor's first name; the customer reads it too, or
  "The team" when the task's team hides staff names — and then the row
  carries no actor at all, so the bell cannot show the name either.

  The rules every kind keeps: the actor is never told of their own act; a
  muted participant hears nothing but a mention; a draft tells nobody
  (QP2-8); the customer hears only about tasks they see, never about a
  staff-only comment; a mentioned person gets *mentioned*, not also
  *commented*.

  Each function answers the socket events its new rows make
  (`notification_created`, and `task_assigned` for *assigned*), for
  `Core.Tasks.Write` to send after commit.
  """

  alias Core.Access
  alias Core.Access.Grants
  alias Core.Access.Tasks, as: TaskAccess
  alias Core.Notifications
  alias Core.Realtime
  alias Core.Tasks.{Histories, Person, Words}
  alias Data.Accounts
  alias Data.Scope

  # ── The kinds ───────────────────────────────────────────────────────────────

  @doc """
  `tasks.assigned` to staff `user_ids` given the task (or the step titled
  `opts[:step]`) in change group `group_id`.
  """
  @spec assigned(Scope.t(), map(), [binary()], binary(), keyword()) :: list()
  def assigned(scope, task, user_ids, group_id, opts \\ []) do
    actor = actor(scope)
    subject = Keyword.get(opts, :step) || task.title
    body = if opts[:step], do: "A step of " <> Words.quoted(task.title)

    for user_id <- quiet(task, user_ids, scope), not draft?(task) do
      ensure(scope, user_id, "tasks.assigned", task,
        title: "#{name(actor, task)} gave you #{Words.quoted(subject)}",
        body: body,
        actor: actor,
        dedupe: "task:#{task.id}:assigned:#{group_id}",
        assigned: true
      )
    end
  end

  @doc "`tasks.assigned` to the customer: the task given to them, or a step for them (`opts[:step]`)."
  @spec assigned_customer(Scope.t(), map(), binary(), keyword()) :: list()
  def assigned_customer(scope, task, group_id, opts \\ []) do
    with_customer(scope, task, fn customer_user_id ->
      actor = actor(scope)
      subject = Keyword.get(opts, :step) || task.title
      {who, actor} = for_customer(actor, task)

      ensure(scope, customer_user_id, "tasks.assigned", task,
        title: "#{who} gave you #{Words.quoted(subject)}",
        body: if(opts[:step], do: "A step of " <> Words.quoted(task.title)),
        actor: actor,
        dedupe: "task:#{task.id}:assigned:#{group_id}",
        assigned: true
      )
    end)
  end

  @doc """
  Everyone a task gives work to, told at once (`tasks.assigned`): when it is
  made, and when a draft becomes real (QP2-8). The assignees, the steps'
  assignees, and the customer when it is given to them or a step is theirs.
  """
  @spec became_real(Scope.t(), map(), binary()) :: list()
  def became_real(scope, task, group_id) do
    staff_steps = for s <- task.steps, s.assignee_user_id, do: s
    customer_step = Enum.find(task.steps, & &1.is_for_customer)

    customer =
      cond do
        task.customer_access == :assigned -> assigned_customer(scope, task, group_id)
        customer_step -> assigned_customer(scope, task, group_id, step: customer_step.title)
        true -> []
      end

    [
      assigned(scope, task, audience(task).assignees, group_id),
      Enum.map(
        staff_steps,
        &assigned(scope, task, [&1.assignee_user_id], group_id, step: &1.title)
      ),
      customer
    ]
  end

  @doc "`tasks.customer_created` to `user_ids` (§9): the owners, else the leads, else the admins."
  @spec customer_created(Scope.t(), map(), [binary()]) :: list()
  def customer_created(scope, task, user_ids) do
    actor = actor(scope)

    for user_id <- Enum.uniq(user_ids), user_id != Scope.user_id(scope) do
      ensure(scope, user_id, "tasks.customer_created", task,
        title: "#{name(actor, task)} added a task: #{Words.quoted(task.title)}",
        actor: actor,
        dedupe: "task:#{task.id}:customer_created"
      )
    end
  end

  @doc """
  `tasks.commented` and `tasks.mentioned` for a comment or reply (`kind`
  `:comment` or `:reply`). `mention_ids` are already the staff who may read
  the task (`mentionable/3`).
  """
  @spec commented(Scope.t(), map(), map(), :comment | :reply, [binary()]) :: list()
  def commented(scope, task, row, kind, mention_ids) do
    actor = actor(scope)
    key = "#{kind}:#{row.id}"
    excerpt = Words.excerpt(row.body)
    mentioned = mention_ids -- [Scope.user_id(scope)]

    mentions =
      for user_id <- mentioned, not draft?(task) do
        ensure(scope, user_id, "tasks.mentioned", task,
          title: "#{name(actor, task)} mentioned you on #{Words.quoted(task.title)}",
          body: excerpt,
          actor: actor,
          dedupe: key <> ":mention"
        )
      end

    audience = audience(task)
    staff = audience.author ++ audience.assignees ++ audience.watchers ++ audience.steps

    staff_told =
      for user_id <- quiet(task, staff, scope) -- mentioned, not draft?(task) do
        ensure(scope, user_id, "tasks.commented", task,
          title: "#{name(actor, task)} commented on #{Words.quoted(task.title)}",
          body: excerpt,
          actor: actor,
          dedupe: key
        )
      end

    customer_told =
      if row.is_staff_only,
        do: [],
        else:
          with_customer(scope, task, fn customer_user_id ->
            {who, actor} = for_customer(actor, task)

            ensure(scope, customer_user_id, "tasks.commented", task,
              title: "#{who} commented on #{Words.quoted(task.title)}",
              body: excerpt,
              actor: actor,
              dedupe: key
            )
          end)

    [mentions, staff_told, customer_told]
  end

  @doc "`tasks.completed`: the author, assignees and watchers, and the customer when they see it."
  @spec completed(Scope.t(), map()) :: list()
  def completed(scope, task) do
    actor = actor(scope)
    dedupe = "task:#{task.id}:done:#{DateTime.to_iso8601(task.done_at)}"
    audience = audience(task)

    staff =
      for user_id <-
            quiet(task, audience.author ++ audience.assignees ++ audience.watchers, scope) do
        ensure(scope, user_id, "tasks.completed", task,
          title: "#{name(actor, task)} marked #{Words.quoted(task.title)} done",
          actor: actor,
          dedupe: dedupe
        )
      end

    customer =
      with_customer(scope, task, fn customer_user_id ->
        {who, actor} = for_customer(actor, task)

        ensure(scope, customer_user_id, "tasks.completed", task,
          title: "#{who} marked #{Words.quoted(task.title)} done",
          actor: actor,
          dedupe: dedupe
        )
      end)

    [staff, customer]
  end

  @doc "`tasks.nudged` to a step's assignee (staff, or the customer), once per organisation day."
  @spec nudged(Scope.t(), map(), map(), Date.t()) :: list()
  def nudged(scope, task, step, %Date{} = day) do
    actor = actor(scope)
    dedupe = "step:#{step.id}:nudge:#{Date.to_iso8601(day)}"
    body = "A step of " <> Words.quoted(task.title)

    cond do
      draft?(task) ->
        []

      step.is_for_customer ->
        with_customer(scope, task, fn customer_user_id ->
          {who, actor} = for_customer(actor, task)

          ensure(scope, customer_user_id, "tasks.nudged", task,
            title: "#{who} nudged you about #{Words.quoted(step.title)}",
            body: body,
            actor: actor,
            dedupe: dedupe
          )
        end)

      step.assignee_user_id && step.assignee_user_id != Scope.user_id(scope) ->
        ensure(scope, step.assignee_user_id, "tasks.nudged", task,
          title: "#{name(actor, task)} nudged you about #{Words.quoted(step.title)}",
          body: body,
          actor: actor,
          dedupe: dedupe
        )

      true ->
        []
    end
  end

  @doc """
  A system notice (`tasks.due_soon`, `tasks.overdue`) to `user_id` with
  `title` already in their words: the due scan's.
  """
  @spec system(Scope.t(), binary(), String.t(), map(), String.t(), String.t()) :: list()
  def system(scope, user_id, kind, task, title, dedupe),
    do: ensure(scope, user_id, kind, task, title: title, actor: nil, dedupe: dedupe)

  # ── The audience ────────────────────────────────────────────────────────────

  @doc """
  The staff a task concerns, by part: `author`, `assignees`, `watchers`,
  `steps` (their assignees) and `muted` — never the customer's own login,
  whose part is `customer_access`.
  """
  @spec audience(map()) :: %{atom() => [binary()]}
  def audience(task) do
    customer_user = customer_user_id(task)
    staff = &Enum.reject(&1, fn id -> is_nil(id) or id == customer_user end)

    %{
      author: staff.([task.author_user_id]),
      assignees: staff.(for(p <- task.participants, p.level, do: p.user_id)),
      watchers: staff.(for(p <- task.participants, p.is_watcher, do: p.user_id)),
      steps: staff.(Enum.map(task.steps, & &1.assignee_user_id)),
      muted: for(p <- task.participants, p.is_muted, do: p.user_id)
    }
  end

  @doc "Of `user_ids`, the staff who may read `task` (their own scopes decide); the rest are ignored."
  @spec mentionable(Scope.t(), map(), [term()]) :: [binary()]
  def mentionable(%Scope{} = scope, task, user_ids) when is_list(user_ids) do
    for id <- Enum.uniq(user_ids),
        is_binary(id),
        id != customer_user_id(task),
        user = Accounts.get_user(id),
        not is_nil(user),
        mention_scope = Grants.scope_for(user),
        Scope.organisation_id(mention_scope) == Scope.organisation_id(scope),
        Scope.staff?(mention_scope),
        Access.can?(mention_scope, :read, {:task, task}),
        do: id
  end

  def mentionable(_scope, _task, _not_a_list), do: []

  # Unique, never the actor, never the muted.
  defp quiet(task, user_ids, scope) do
    muted = audience(task).muted
    me = Scope.user_id(scope)
    user_ids |> Enum.uniq() |> Enum.reject(&(&1 == me or &1 in muted))
  end

  defp draft?(task), do: task.state == :draft

  # The customer's login, when they see the task and are not the actor.
  defp with_customer(scope, task, fun) do
    case customer_user_id(task) do
      nil ->
        []

      id ->
        if id != Scope.user_id(scope) and TaskAccess.customer_sees?(task), do: fun.(id), else: []
    end
  end

  defp customer_user_id(%{customer: %{user_id: id}}), do: id
  defp customer_user_id(_task), do: nil

  # The actor as the customer is told: their first name and themselves as
  # the row's actor, or "The team" and no actor when names are hidden.
  defp for_customer(nil, _task), do: {"The team", nil}

  defp for_customer(actor, task) do
    if Histories.names?(task), do: {name(actor), actor}, else: {"The team", nil}
  end

  defp actor(scope) do
    case Scope.user_id(scope) do
      nil -> nil
      id -> Accounts.get_user(id)
    end
  end

  defp name(nil), do: "The team"
  defp name(actor), do: Person.first_name(actor) || "Someone"

  # The team knows the task's customer by the customer's name ("Tanweer"),
  # not by the first word of the account behind it.
  defp name(%{id: id}, %{customer: %{user_id: id, display_name: customer_name}}),
    do: customer_name

  defp name(actor, _task), do: name(actor)

  defp ensure(scope, user_id, kind, task, opts) do
    actor = opts[:actor]

    {:ok, row} =
      Notifications.ensure(scope, %{
        organisation_id: task.organisation_id,
        user_id: user_id,
        notification_kind_key: kind,
        actor_user_id: actor && actor.id,
        task_id: task.id,
        title: opts[:title],
        body: opts[:body],
        link_path: "/board/#{task.id}",
        dedupe_key: opts[:dedupe]
      })

    cond do
      not row.is_new ->
        []

      opts[:assigned] ->
        [created(row), Realtime.to_user(user_id, "task_assigned", %{task: task.id})]

      true ->
        [created(row)]
    end
  end

  defp created(row), do: Realtime.to_user(row.user_id, "notification_created", %{id: row.id})
end
