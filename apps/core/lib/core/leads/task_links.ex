defmodule Core.Leads.TaskLinks do
  @moduledoc """
  Tasks on a lead (AQ-04B §4, §10, QP4b-14). `POST /tasks` takes `lead_id`:
  the lead must be one the caller may change (`:add_task`, P2's and §4.2's
  words) and **in the task's team**; the task is about the lead's customer
  and profile unless the body names them (and then they must be the
  lead's). Inside the task's own transaction it writes `task_created` on
  the lead, and when the task is done `task_done` — each **customer-visible
  when the task is shown to the customer**, else staff, and each a
  person's act, so activity. The lead's topics hear `lead_updated`, so its
  *Next* re-reads.
  """

  alias Core.Access.Tasks, as: TaskAccess
  alias Core.Leads
  alias Core.Leads.Ledger
  alias Core.Realtime
  alias Data.Leads, as: Store
  alias Data.Scope

  @doc """
  The lead a new task names, checked: `{:ok, nil}` without one; else
  `{:ok, %{lead_id, customer_id, profile_id}}` to merge into the task's
  attributes.
  """
  @spec for_new_task(Scope.t(), binary(), map()) :: {:ok, map() | nil} | {:error, term()}
  def for_new_task(%Scope{} = scope, team_id, params) do
    case Leads.blank(params["lead_id"]) do
      nil -> {:ok, nil}
      id -> link(scope, team_id, id, params)
    end
  end

  defp link(scope, team_id, id, params) do
    with {:ok, lead} <- Leads.fetch(scope, :add_task, id),
         :ok <- same_team(lead, team_id),
         :ok <- same(params, "customer_id", lead.profile.customer_id),
         :ok <- same(params, "profile_id", lead.profile_id) do
      {:ok,
       %{
         "lead_id" => lead.id,
         "customer_id" => lead.profile.customer_id,
         "profile_id" => lead.profile_id
       }}
    end
  end

  defp same_team(lead, team_id) do
    if lead.job.team_id == team_id,
      do: :ok,
      else: Leads.invalid("lead_id", "is in another team: a task on a lead is in the lead's team")
  end

  defp same(params, field, value) do
    case Leads.blank(params[field]) do
      nil -> :ok
      ^value -> :ok
      _other -> Leads.invalid(field, "is not the lead's")
    end
  end

  @doc "A task made on a lead: `task_created`. Answers the realtime events."
  @spec created(Scope.t(), map(), DateTime.t()) :: list()
  def created(_scope, %{lead_id: nil}, _now), do: []
  def created(scope, task, now), do: record(scope, task, :task_created, now)

  @doc "A task moved: `task_done` when it became done. Answers the realtime events."
  @spec moved(Scope.t(), map(), map(), DateTime.t()) :: list()
  def moved(scope, %{state: before}, %{state: :done, lead_id: lead_id} = task, now)
      when before != :done and is_binary(lead_id),
      do: record(scope, task, :task_done, now)

  def moved(_scope, _before, _task, _now), do: []

  defp record(scope, task, kind, now) do
    case Store.get(task.organisation_id, task.lead_id) do
      nil ->
        []

      lead ->
        visibility = if TaskAccess.customer_sees?(task), do: :customer, else: :staff

        _event =
          Ledger.record(
            scope,
            lead,
            kind,
            %{to_label: task.title, task_id: task.id, visibility: visibility},
            now
          )

        Realtime.lead_events("lead_updated", lead)
    end
  end
end
