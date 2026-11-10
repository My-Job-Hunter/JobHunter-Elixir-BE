defmodule Core.Access.Grants do
  @moduledoc """
  Resolves who somebody is, once per request, into the scope (JH-01 §5.1).

  `roles` is `%{admin?: boolean, teams: %{team_id => :manager | :lead |
  :member}, customer_id: id | nil, team_settings: %{team_id => settings}}`:

  - `admin?` from `org_admins`;
  - `teams` from the open `team_members` rows in unarchived teams;
  - `customer_id` from `customers.user_id` — the customer this account signs
    in as, which the portal's `ApiClient.Plugs.CustomerScope` requires and
    pins (`Data.Scope.pin_to_customer/1`);
  - `team_settings` of the caller's teams, so a later phase consults a
    visibility toggle (PLAN §3.4) without another query.

  The organisation is the one the roles point at, or the one organisation
  (PLAN Q1) for an account with no role yet. Nothing is cached: it is per
  request, a handful of indexed reads.
  """

  alias Data.Customers
  alias Data.Organisations
  alias Data.Scope
  alias Data.Teams

  @doc "The scope for an account: the organisation, the roles, and how the request arrived."
  @spec scope_for(struct() | map(), keyword()) :: Scope.t()
  def scope_for(%{id: user_id} = user, opts \\ []) do
    admin_of = Organisations.admin_of(user_id)
    memberships = Teams.memberships_of(user_id)
    customer = Customers.get_by_user(user_id)

    organisation =
      case admin_of ++
             Enum.map(memberships, & &1.team.organisation_id) ++
             List.wrap(customer && customer.organisation_id) do
        [] -> Organisations.the_one()
        [organisation_id | _rest] -> Organisations.get(organisation_id)
      end

    teams =
      memberships
      |> Enum.filter(&(is_nil(organisation) or &1.team.organisation_id == organisation.id))
      |> Map.new(&{&1.team_id, &1.role})

    %Scope{
      user: user,
      organisation: organisation,
      roles: %{
        admin?: not is_nil(organisation) and organisation.id in admin_of,
        teams: teams,
        customer_id: customer_id(customer, organisation),
        team_settings: teams |> Map.keys() |> Teams.settings_for()
      },
      via: Keyword.get(opts, :via, :web),
      request_id: Keyword.get(opts, :request_id)
    }
  end

  defp customer_id(%{id: id, organisation_id: org_id}, %{id: org_id}), do: id
  defp customer_id(_customer, _organisation), do: nil
end
