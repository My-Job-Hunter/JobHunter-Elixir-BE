defmodule Core.Access.Tasks do
  @moduledoc """
  Who sees and does what to a task (AQ-02 §6.1, §6.2), **pure**: the
  `{:task, task}` rows of `Core.Access`. The task carries `participants`
  and `steps` (`Data.Tasks` loads them with every read).

  **Seeing** (AQ-02 §6.1, AQ-03B §3.2): a draft is its author's alone
  (QP2-8). Otherwise the author, a participant (assignee or watcher) or a
  step's assignee; a lead of its team; an admin; a member of its
  team when the team's `peer_tasks` is `view` or `edit` (read from
  `Data.Scope.team_settings/2`). The customer sees a live, non-draft task
  about them that is shared with or given to them. Anyone else — a person
  of another team, a member at `hidden` — `:not_found`.

  **Changing** (QP2-7, QT-7): the author, the assignees, the team's leads, the system admin, and a member of the team at `peer_tasks: edit`.
  Whoever else sees it (a member at `view`, a watcher, a step's assignee)
  may comment, reply and watch. Who the customer sees it as
  (`customer_access`) is the author's or a lead's to decide, and a draft's
  delete the author's (QT-8), whatever the level.
  """

  alias Data.Scope

  @edit_actions [
    :edit,
    :move,
    :assign,
    :checklist,
    :steps,
    :links,
    :relations,
    :files,
    :archive,
    :tick,
    :complete,
    :withdraw,
    :edit_own
  ]
  @talk_actions [:comment, :comment_staff_only, :watch]

  @change_words "Only the people on this task, or a lead, can change it."
  @view_words "You can see this, but only its people or a team lead can change it."
  @visibility_words "Only the task's author or a lead can change who sees it."
  @delete_words "Only a draft can be deleted. Archive it instead."
  @team_words "That is for the team serving you to do."
  @not_given_words "This task isn't yours to do."
  @own_words "You can change a task you added while it is still To do."
  @withdraw_words "Only a task you added can be withdrawn."

  @doc "Every action a task subject answers, for the matrix."
  def actions, do: [:read, :change_visibility, :delete | @edit_actions ++ @talk_actions]

  @doc "The decision for `action` on `task`."
  @spec decide(Scope.t(), atom(), map()) :: :ok | {:error, term()}
  def decide(%Scope{} = scope, action, task) do
    if Scope.customer?(scope),
      do: customer(scope, action, task),
      else: staff(scope, action, task)
  end

  @doc "§6.1: whether the caller sees the task at all."
  @spec visible?(Scope.t(), map()) :: boolean()
  def visible?(%Scope{} = scope, task) do
    if Scope.customer?(scope), do: customer_sees?(scope, task), else: staff_sees?(scope, task)
  end

  @doc "Whether the customer of the task sees it: shared or given, not a draft, not archived."
  @spec customer_sees?(map()) :: boolean()
  def customer_sees?(task) do
    task.customer_access in [:shared, :assigned] and task.state != :draft and
      is_nil(task.archived_at)
  end

  # ── Staff ───────────────────────────────────────────────────────────────────

  defp staff(scope, action, task) do
    cond do
      not staff_sees?(scope, task) -> {:error, :not_found}
      action == :read or action in @talk_actions -> :ok
      action in @edit_actions -> allow(editor?(scope, task), refusal(scope, task))
      action == :change_visibility -> visibility(scope, task)
      action == :delete -> allow(task.state == :draft and author?(scope, task), @delete_words)
      true -> {:error, :not_found}
    end
  end

  defp visibility(scope, task) do
    cond do
      author?(scope, task) or leads_team?(scope, task) or Scope.admin?(scope) -> :ok
      editor?(scope, task) -> {:error, {:forbidden, @visibility_words}}
      true -> {:error, {:forbidden, refusal(scope, task)}}
    end
  end

  defp staff_sees?(scope, task) do
    cond do
      author?(scope, task) -> true
      task.state == :draft -> false
      on_it?(scope, task) -> true
      leads_team?(scope, task) -> true
      Scope.admin?(scope) -> true
      true -> peer_level(scope, task) in [:view, :edit]
    end
  end

  # The author, an assignee, a lead of its team, an admin, a
  # member of its team at `edit`.
  defp editor?(scope, task) do
    author?(scope, task) or assignee?(scope, task) or leads_team?(scope, task) or
      Scope.admin?(scope) or peer_level(scope, task) == :edit
  end

  # A member who sees it through the team's `view` hears the level's words;
  # a watcher or a step's assignee, P2's.
  defp refusal(scope, task) do
    if peer_level(scope, task) == :view and not on_it?(scope, task),
      do: @view_words,
      else: @change_words
  end

  defp author?(scope, task),
    do: not is_nil(task.author_user_id) and task.author_user_id == me(scope)

  defp assignee?(scope, task),
    do: Enum.any?(task.participants, &(&1.user_id == me(scope) and not is_nil(&1.level)))

  defp on_it?(scope, task) do
    me = me(scope)

    Enum.any?(task.participants, &(&1.user_id == me and (&1.level || &1.is_watcher))) or
      Enum.any?(task.steps, &(&1.assignee_user_id == me))
  end

  defp leads_team?(scope, task), do: Scope.team_role(scope, task.team_id) == :lead

  # The team's `peer_tasks` for a member of it; `nil` for anyone else.
  defp peer_level(scope, task) do
    with :member <- Scope.team_role(scope, task.team_id),
         %{peer_tasks: level} <- Scope.team_settings(scope, task.team_id) do
      level
    else
      _other -> nil
    end
  end

  defp me(scope), do: Scope.user_id(scope)

  # ── The customer ────────────────────────────────────────────────────────────

  defp customer(scope, action, task) do
    cond do
      not customer_sees?(scope, task) -> {:error, :not_found}
      action in [:read, :comment, :files] -> :ok
      action in [:tick, :complete] -> allow(task.customer_access == :assigned, @not_given_words)
      action == :withdraw -> allow(task.source == :customer, @withdraw_words)
      action == :edit_own -> allow(task.source == :customer and task.state == :todo, @own_words)
      true -> {:error, {:forbidden, @team_words}}
    end
  end

  defp customer_sees?(scope, task),
    do: task.customer_id == Scope.customer_id(scope) and customer_sees?(task)

  defp allow(true, _words), do: :ok
  defp allow(false, words), do: {:error, {:forbidden, words}}
end
