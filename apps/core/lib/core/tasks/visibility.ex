defmodule Core.Tasks.Visibility do
  @moduledoc """
  §6.1 of AQ-02 with AQ-03B §3.2's levels, **composed into every task
  query**: the caller's roles turned into the plain map `Data.Tasks.visible/2`
  filters by. The rule for one task in hand is `Core.Access.Tasks.visible?/2`;
  the two say the same thing and `Core.TaskAccessMatrixTest` holds both to
  it.
  """

  alias Data.Scope

  @doc """
  The filter for the caller: the customer's (pinned) or staff's, with the
  teams they lead and the teams where they are a member and the
  team's `peer_tasks` is `view` or `edit`.
  """
  @spec filter(Scope.t()) :: map()
  def filter(%Scope{} = scope) do
    organisation_id = Scope.organisation_id(scope)

    if Scope.customer?(scope) do
      %{organisation_id: organisation_id, customer_id: Scope.customer_id(scope)}
    else
      teams = scope.roles.teams

      %{
        organisation_id: organisation_id,
        user_id: Scope.user_id(scope),
        admin?: Scope.admin?(scope),
        lead_team_ids: for({id, role} <- teams, role == :lead, do: id),
        peer_team_ids: for({id, :member} <- teams, peers?(scope, id), do: id)
      }
    end
  end

  @doc "Whether a member of `team_id` sees their teammates' tasks (`peer_tasks` not `hidden`)."
  @spec peers?(Scope.t(), binary()) :: boolean()
  def peers?(%Scope{} = scope, team_id) do
    case Scope.team_settings(scope, team_id) do
      %{peer_tasks: level} -> level in [:view, :edit]
      nil -> false
    end
  end
end
