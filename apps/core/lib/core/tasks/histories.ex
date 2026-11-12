defmodule Core.Tasks.Histories do
  @moduledoc """
  A task's activity (AQ-02 §5.1, §6.4; mCart's): **one row per changed
  field**, the rows of one save sharing a `change_group_id`, **labels frozen
  at write** in the organisation's zone, so renaming a stage never rewrites
  what the log said. Written inside the verb's transaction (`write/5`).

  **What the customer reads** is decided here, on read (§6.4): created,
  title, description, state, due, customer access (when it became
  visible), checklist, step, file, link, archived — and assignees as
  "Fiza is on it", or "The team is on it" when the team hides names. Never
  stage, priority, team, private (P2's, gone in AQ-03B), watchers, relation
  or reminder.
  Comments write no history at all, so a staff-only one leaves nothing the
  customer could infer it from.
  """

  alias Core.Tasks.{Person, Words}
  alias Data.Customers.Customer
  alias Data.Profiles
  alias Data.Repo
  alias Data.Scope
  alias Data.TaskHistories
  alias Data.Tasks.Stage
  alias Data.Teams

  @customer_fields ~w(created title description state due customer_access checklist step file
                      link archived assignees)a

  # ── Writing ─────────────────────────────────────────────────────────────────

  @doc "A fresh change group id."
  def group_id, do: Ecto.UUID.generate()

  @doc "One line: a field, its values before and after, and how each reads."
  @spec line(atom(), term(), term(), String.t() | nil, String.t() | nil) :: map()
  def line(field, from, to, from_label, to_label) do
    %{
      field: field,
      from_value: value(from),
      to_value: value(to),
      from_label: clip(from_label),
      to_label: clip(to_label)
    }
  end

  @doc "The lines a task's own columns make between `before` and `after_task` (`nil` before: none)."
  @spec diff(map(), map(), String.t()) :: [map()]
  def diff(before, after_task, zone) do
    [
      simple(:title, before.title, after_task.title, & &1),
      description(before.description, after_task.description),
      simple(:state, before.state, after_task.state, &Words.state/1),
      simple(:stage, before.stage_id, after_task.stage_id, &stage_name/1),
      simple(:priority, before.priority, after_task.priority, &Words.priority/1, true),
      simple(:due, due(before), due(after_task), &Words.due(&1, zone)),
      simple(:reminder, before.reminder_minutes, after_task.reminder_minutes, &Words.reminder/1),
      simple(:team, before.team_id, after_task.team_id, &team_name/1),
      simple(:customer, before.customer_id, after_task.customer_id, &customer_name/1),
      simple(:profile, before.profile_id, after_task.profile_id, &profile_title/1),
      access(before, after_task)
    ]
    |> Enum.reject(&is_nil/1)
  end

  @doc "Writes `lines` as one change group by the caller, at `now`; lines that change nothing are dropped."
  @spec write(Scope.t(), binary(), binary(), [map()], DateTime.t()) :: :ok
  def write(%Scope{} = scope, task_id, group_id, lines, %DateTime{} = now) do
    lines
    |> Enum.reject(&(&1.from_value == &1.to_value))
    |> Enum.map(
      &Map.merge(&1, %{
        task_id: task_id,
        actor_user_id: Scope.user_id(scope),
        change_group_id: group_id,
        changed_at: now
      })
    )
    |> TaskHistories.record()
  end

  defp simple(field, from, to, label, always_label \\ false)
  defp simple(_field, same, same, _label, _always), do: nil

  defp simple(field, from, to, label, always) do
    from_label = if always or not is_nil(from), do: label.(from)
    to_label = if always or not is_nil(to), do: label.(to)
    line(field, from, to, from_label, to_label)
  end

  # Body text is not diffed (mCart): a fingerprint satisfies the CHECK,
  # and the line says *that* it changed.
  defp description(same, same), do: nil

  defp description(from, to),
    do: line(:description, digest(from), digest(to), nil, if(to, do: "Changed", else: "Removed"))

  defp digest(nil), do: nil

  defp digest(text),
    do: :sha256 |> :crypto.hash(text) |> Base.encode16(case: :lower) |> binary_slice(0, 16)

  defp due(%{due_at: %DateTime{} = at}), do: at
  defp due(%{due_on: %Date{} = on}), do: on
  defp due(_task), do: nil

  defp access(%{customer_access: same}, %{customer_access: same}), do: nil

  defp access(before, after_task) do
    line(
      :customer_access,
      before.customer_access,
      after_task.customer_access,
      access_label(before),
      access_label(after_task)
    )
  end

  @doc ~s(The customer's part as the sheet says it: "Staff only", "Tanweer sees this task", "Tanweer has to do it".)
  def access_label(%{customer_access: :none}), do: "Staff only"

  def access_label(%{customer_access: :shared} = task),
    do: "#{customer_first(task)} sees this task"

  def access_label(%{customer_access: :assigned} = task),
    do: "#{customer_first(task)} has to do it"

  defp customer_first(%{customer: %{display_name: name}}),
    do: Words.first_name(%{display_name: name})

  defp customer_first(%{customer_id: id}) when is_binary(id), do: first_of(customer_name(id))
  defp customer_first(_task), do: "The customer"

  defp first_of(nil), do: "The customer"
  defp first_of(name), do: Words.first_name(%{display_name: name})

  defp stage_name(id) do
    case Repo.get(Stage, id) do
      nil -> nil
      stage -> stage.name
    end
  end

  defp team_name(id) do
    case Teams.by_id([id]) do
      %{^id => team} -> team.name
      _gone -> nil
    end
  end

  defp customer_name(id) do
    case Repo.get(Customer, id) do
      nil -> nil
      customer -> customer.display_name
    end
  end

  defp profile_title(id) do
    case Profiles.get(id) do
      nil -> nil
      profile -> profile.title
    end
  end

  defp value(nil), do: nil
  defp value(%DateTime{} = at), do: DateTime.to_iso8601(at)
  defp value(%Date{} = on), do: Date.to_iso8601(on)
  defp value(v) when is_atom(v), do: Atom.to_string(v)
  defp value(v), do: to_string(v)

  defp clip(nil), do: nil
  defp clip(label), do: String.slice(label, 0, 255)

  # ── Reading ─────────────────────────────────────────────────────────────────

  @doc """
  `GET /tasks/:id/history`: change groups newest first, each `{change_group_id,
  actor, changed_at, lines}`. The customer reads §6.4's rows only.
  """
  @spec list(Scope.t(), map()) :: [map()]
  def list(%Scope{} = scope, task) do
    rows = TaskHistories.list(task.id)

    if Scope.customer?(scope),
      do:
        rows
        |> Enum.filter(&for_customer?/1)
        |> group(&customer_line(&1, names?(task)), &customer_actor(&1, task)),
      else: group(rows, &staff_line/1, &Person.view(&1, customer: task.customer))
  end

  defp group(rows, line, actor) do
    rows
    |> Enum.chunk_by(& &1.change_group_id)
    |> Enum.map(fn [first | _rest] = chunk ->
      %{
        change_group_id: first.change_group_id,
        actor: actor.(first.actor_user),
        changed_at: first.changed_at,
        lines: chunk |> Enum.reverse() |> Enum.map(line)
      }
    end)
  end

  defp staff_line(row),
    do: %{field: row.field, from_label: row.from_label, to_label: row.to_label}

  defp for_customer?(%{field: :customer_access} = row),
    do: row.from_value in [nil, "none"] and row.to_value in ["shared", "assigned"]

  defp for_customer?(row), do: row.field in @customer_fields

  defp customer_line(%{field: :assignees} = row, names?) do
    count = if row.to_value, do: length(String.split(row.to_value, ",")), else: 0

    to =
      cond do
        count == 0 -> "Nobody is on it yet"
        not names? -> "The team is on it"
        count == 1 -> "#{row.to_label} is on it"
        true -> "#{row.to_label} are on it"
      end

    %{field: :assignees, from_label: nil, to_label: to}
  end

  defp customer_line(%{field: :step} = row, false),
    do: %{field: :step, from_label: unnamed(row.from_label), to_label: unnamed(row.to_label)}

  defp customer_line(row, _names?), do: staff_line(row)

  # A step's label names its assignee after " · "; with names hidden it goes.
  defp unnamed(nil), do: nil
  defp unnamed(label), do: label |> String.split(" · ") |> hd()

  defp customer_actor(user, task),
    do: Person.for_customer(user, task.customer, names?(task))

  @doc "Whether the customer reads staff names on this task (its team's `customer_sees_staff_names`)."
  @spec names?(map()) :: boolean()
  def names?(%{team_id: nil}), do: true
  def names?(%{team_id: team_id}), do: Teams.get_settings(team_id).customer_sees_staff_names
end
