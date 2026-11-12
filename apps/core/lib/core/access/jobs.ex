defmodule Core.Access.Jobs do
  @moduledoc """
  Who does what to a job and a company (AQ-03 §4, AQ-03B §3.2), **pure**:
  the `{:job, _}` and `{:company, _}` rows of `Core.Access`.

  **A job is in one team's pool** and carries `team_id` and
  `created_by_user_id`. An **admin** does everything, in every team. In the
  job's team, its **creator** and the team's **leads** read and
  change it; **another member** follows the team's `peer_jobs` (read from
  `Data.Scope.team_settings/2`): `hidden` — the job is not found; `view` —
  read only, every change refused with the view-only words; `edit` — as
  their own. **Merge, archive and unarchive** stay a team lead's or the system
  admin's (QP3-7, QT-8), refused with §4.2's words to
  whoever else sees the job. Anyone outside the team — and every customer,
  and anyone of another organisation — finds nothing (`:not_found`).

  A subject not made yet (no `id`: the list, the check, a new job) is
  decided on the team it names, `team_id`: a member of it, or an admin. With
  no team at all it answers for any staff member, as P3's did.

  **Companies stay the organisation's** (QT-2): any staff member reads,
  adds and edits one; the card's open jobs are narrowed by the context.
  """

  alias Data.Scope

  @change_actions [:edit, :close, :reopen, :dismiss]
  @lead_actions [:merge, :archive, :unarchive]
  @company_actions [:read, :create, :update]

  @lead_words "Only a lead can merge or archive a job."
  @view_words "You can see this, but only its people or a team lead can change it."

  @doc "Every action a job answers, for the matrix."
  def job_actions, do: [:read, :check, :create] ++ @change_actions ++ @lead_actions

  @doc "Every action a company answers, for the matrix."
  def company_actions, do: @company_actions

  @doc "The words a member is refused a merge or an archive with (§4.2)."
  def lead_words, do: @lead_words

  @doc "The words a member at `view` is refused a change with (AQ-03B §6)."
  def view_words, do: @view_words

  @doc "The decision for `action` on a job or a company."
  @spec decide(Scope.t(), atom(), {:job | :company, map()}) :: :ok | {:error, term()}
  def decide(%Scope{} = scope, action, {kind, subject}) when kind in [:job, :company] do
    cond do
      not Scope.staff?(scope) or Scope.customer?(scope) -> {:error, :not_found}
      not same_organisation?(scope, subject) -> {:error, :not_found}
      kind == :company -> company(action)
      is_nil(Map.get(subject, :id)) -> unmade(scope, action, subject)
      true -> job(scope, action, subject)
    end
  end

  @doc "Whether the caller sees `job` at all (the list's rule, for one job)."
  @spec visible?(Scope.t(), map()) :: boolean()
  def visible?(%Scope{} = scope, job), do: decide(scope, :read, {:job, job}) == :ok

  @doc """
  What the caller sees of a team's pool: `:all` (the system admin, the team's leads, a member at `view` or `edit`), `{:own, user_id}` (a member at
  `hidden`), or `:none` (not in the team).
  """
  @spec pool_reach(Scope.t(), binary()) :: :all | {:own, binary()} | :none
  def pool_reach(%Scope{} = scope, team_id) do
    cond do
      Scope.admin?(scope) -> :all
      Scope.team_role(scope, team_id) == :lead -> :all
      Scope.team_role(scope, team_id) != :member -> :none
      peer_level(scope, team_id) == :hidden -> {:own, Scope.user_id(scope)}
      true -> :all
    end
  end

  # ── A job not made yet: the team it names decides ───────────────────────────

  defp unmade(scope, action, subject) when action in [:read, :check, :create] do
    case Map.get(subject, :team_id) do
      nil -> :ok
      team_id -> if in_team?(scope, team_id), do: :ok, else: {:error, :not_found}
    end
  end

  defp unmade(_scope, _action, _subject), do: {:error, :not_found}

  # ── A job ───────────────────────────────────────────────────────────────────

  defp job(scope, action, job) do
    cond do
      not sees?(scope, job) -> {:error, :not_found}
      action in [:read, :check, :create] -> :ok
      action in @change_actions -> allow(changer?(scope, job), @view_words)
      action in @lead_actions -> allow(leads?(scope, job.team_id), @lead_words)
      true -> {:error, :not_found}
    end
  end

  defp sees?(scope, job) do
    Scope.admin?(scope) or creator?(scope, job) or leads?(scope, job.team_id) or
      peer_level(scope, job.team_id) in [:view, :edit]
  end

  defp changer?(scope, job) do
    Scope.admin?(scope) or creator?(scope, job) or leads?(scope, job.team_id) or
      peer_level(scope, job.team_id) == :edit
  end

  # The creator, while they are still in the job's team.
  defp creator?(scope, job) do
    not is_nil(job.created_by_user_id) and job.created_by_user_id == Scope.user_id(scope) and
      not is_nil(Scope.team_role(scope, job.team_id))
  end

  defp leads?(scope, team_id),
    do: Scope.admin?(scope) or Scope.team_role(scope, team_id) == :lead

  defp in_team?(scope, team_id),
    do: Scope.admin?(scope) or not is_nil(Scope.team_role(scope, team_id))

  # The team's `peer_jobs` for a member of it; `nil` for anyone else.
  defp peer_level(scope, team_id) do
    with :member <- Scope.team_role(scope, team_id),
         %{peer_jobs: level} <- Scope.team_settings(scope, team_id) do
      level
    else
      _other -> nil
    end
  end

  defp company(action) when action in @company_actions, do: :ok
  defp company(_action), do: {:error, :not_found}

  defp same_organisation?(scope, %{organisation_id: org_id}) when is_binary(org_id),
    do: org_id == Scope.organisation_id(scope)

  defp same_organisation?(_scope, _subject), do: true

  defp allow(true, _words), do: :ok
  defp allow(false, words), do: {:error, {:forbidden, words}}
end
