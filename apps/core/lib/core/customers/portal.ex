defmodule Core.Customers.Portal do
  @moduledoc """
  What only the portal asks (JH-01 §6.3): "who serves me". Everything else
  the portal does goes through the same verbs the console uses, on a scope
  pinned to the customer (`ApiClient.Plugs.CustomerScope`).
  """

  alias Core.Customers
  alias Data.Scope
  alias Data.Teams

  @doc """
  `GET /team`: the teams serving the customer, each with the first names
  of the profile owners who are in it — only when that team's
  `customer_sees_staff_names` is on (PLAN §3.4). Answers
  `[%{team_id, name, first_names}]`.
  """
  @spec who_serves(Scope.t()) :: {:ok, [map()]} | {:error, term()}
  def who_serves(%Scope{} = scope) do
    with {:ok, customer} <- Customers.fetch(scope, :read, Scope.customer_id(scope) || "") do
      team_ids = customer.team_ids
      settings = Teams.settings_for(team_ids)
      members = team_ids |> Teams.memberships_in() |> Enum.group_by(& &1.team_id)

      owners =
        customer.profiles
        |> Enum.reject(& &1.archived_at)
        |> Enum.flat_map(& &1.profile_members)
        |> Map.new(&{&1.user_id, &1.user.person})

      teams =
        for link <- customer.customer_teams, team = link.team, is_nil(team.archived_at) do
          %{
            team_id: team.id,
            name: team.name,
            first_names: first_names(settings[team.id], members[team.id] || [], owners)
          }
        end

      {:ok, teams}
    end
  end

  defp first_names(%{customer_sees_staff_names: false}, _members, _owners), do: []

  defp first_names(_settings, members, owners) do
    members
    |> Enum.map(& &1.user_id)
    |> Enum.filter(&Map.has_key?(owners, &1))
    |> Enum.map(&first_name(owners[&1]))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp first_name(%{given_name: given}) when is_binary(given) and given != "", do: given

  defp first_name(%{display_name: name}),
    do: name |> String.split(" ", trim: true) |> List.first() || name
end
