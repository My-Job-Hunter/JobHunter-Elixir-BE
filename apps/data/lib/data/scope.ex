defmodule Data.Scope do
  @moduledoc """
  Who is asking.

  **Every context function takes one of these first** (`docs/CONVENTIONS.md`
  §2), and there are no unscoped queries. A customer must never reach another
  customer's rows, and a member must see only what their team settings allow
  (PLAN §3), so "whose data is this, and how much of it" is a question on
  every read.

  ## What it holds

  | Field | Is | Filled by |
  |---|---|---|
  | `user` | the signed-in account, with its person | `ApiShared.Plugs.Scope`, from the token |
  | `organisation` | the organisation the request acts in (one now, Q1) | `Core.Access.Grants` |
  | `roles` | `%{admin?: boolean, teams: %{team_id => :lead \\| :member}, customer_id: id \\| nil, team_settings: %{team_id => settings}}` | `Core.Access.Grants` (AQ-01 §5.1) |
  | `via` | how the request arrived: `:web`, `:extension`, `:task`, `:system` | the plug (`:web`); `system/0` (`:system`) |
  | `request_id` | `Plug.RequestId`'s, for the audit row | the plug |

  `roles.customer_id` is the customer this account signs in as
  (`customers.user_id`), or `nil` for staff. The portal's
  `ApiClient.Plugs.CustomerScope` refuses a request whose scope has none and
  **pins** the one it accepts: `teams` emptied, `admin?` false, so no portal
  route can act with a staff role. `roles.team_settings` holds the
  `team_settings` rows of the caller's teams, so a later phase consults a
  visibility toggle without a query. `via` and `request_id` are here because
  `Core.Audit.record/4` writes them with every change, and the scope is the
  one thing every write already carries.

  **It lives in `data`, not `core`, and that is forced rather than chosen.**
  Every data function takes one, and `data` must not depend on `core` — so
  the app that needs it in a function head has to own it. Only the
  *decisions* made with it (`Core.Access`) are business logic.
  """

  defstruct user: nil, organisation: nil, roles: nil, via: :web, request_id: nil

  @type team_role :: :lead | :member
  @type roles :: %{
          admin?: boolean(),
          teams: %{optional(binary()) => team_role()},
          customer_id: binary() | nil,
          team_settings: %{optional(binary()) => struct() | map()}
        }

  @type t :: %__MODULE__{
          user: struct() | map() | nil,
          organisation: struct() | map() | nil,
          roles: roles() | nil,
          via: :web | :extension | :task | :system,
          request_id: String.t() | nil
        }

  @doc "The roles of somebody with none: not an admin, in no team, not a customer."
  @spec no_roles() :: roles()
  def no_roles, do: %{admin?: false, teams: %{}, customer_id: nil, team_settings: %{}}

  @doc """
  A scope for an authenticated account, with no roles resolved yet.
  `Core.Access.Grants.scope_for/2` is what fills the organisation and roles.
  """
  @spec for_user(struct() | map()) :: t()
  def for_user(%{id: _id} = user), do: %__MODULE__{user: user, roles: no_roles()}

  @doc """
  The system acting on its own: a mix task, a job. Nobody is the actor, and
  the audit row says `via: system`.
  """
  @spec system(struct() | map() | nil) :: t()
  def system(organisation \\ nil),
    do: %__MODULE__{organisation: organisation, roles: no_roles(), via: :system}

  @doc """
  The same scope pinned to its customer (AQ-01 §5.1): the staff roles are
  dropped, so every portal query binds to `roles.customer_id` and nothing
  else. Answers `nil` for an account that is nobody's customer.
  """
  @spec pin_to_customer(t()) :: t() | nil
  def pin_to_customer(%__MODULE__{roles: %{customer_id: id}} = scope) when is_binary(id) do
    %{scope | roles: %{no_roles() | customer_id: id}}
  end

  def pin_to_customer(%__MODULE__{}), do: nil

  @doc "The acting account's id, or `nil` for a scope with nobody in it."
  @spec user_id(t()) :: binary() | nil
  def user_id(%__MODULE__{user: %{id: id}}), do: id
  def user_id(%__MODULE__{}), do: nil

  @doc "The organisation's id, or `nil`."
  @spec organisation_id(t()) :: binary() | nil
  def organisation_id(%__MODULE__{organisation: %{id: id}}), do: id
  def organisation_id(%__MODULE__{}), do: nil

  @doc "Whether the caller administers the organisation."
  @spec admin?(t()) :: boolean()
  def admin?(%__MODULE__{roles: %{admin?: true}}), do: true
  def admin?(%__MODULE__{}), do: false

  @doc "The customer this scope acts as, or `nil` for staff."
  @spec customer_id(t()) :: binary() | nil
  def customer_id(%__MODULE__{roles: %{customer_id: id}}), do: id
  def customer_id(%__MODULE__{}), do: nil

  @doc "Whether the caller is signed in as a customer."
  @spec customer?(t()) :: boolean()
  def customer?(%__MODULE__{} = scope), do: not is_nil(customer_id(scope))

  @doc "Whether the caller holds any staff role: admin, or in a team."
  @spec staff?(t()) :: boolean()
  def staff?(%__MODULE__{} = scope), do: admin?(scope) or team_ids(scope) != []

  @doc "The caller's role in a team, or `nil` when they are not in it."
  @spec team_role(t(), binary()) :: team_role() | nil
  def team_role(%__MODULE__{roles: %{teams: teams}}, team_id), do: Map.get(teams, team_id)
  def team_role(%__MODULE__{}, _team_id), do: nil

  @doc "The ids of the teams the caller is in."
  @spec team_ids(t()) :: [binary()]
  def team_ids(%__MODULE__{roles: %{teams: teams}}), do: Map.keys(teams)
  def team_ids(%__MODULE__{}), do: []

  @doc "Whether the caller holds `role` in any team."
  @spec any_team?(t(), team_role()) :: boolean()
  def any_team?(%__MODULE__{roles: %{teams: teams}}, role), do: role in Map.values(teams)
  def any_team?(%__MODULE__{}, _role), do: false

  @doc """
  The caller's strongest role across `team_ids` (`:lead` > `:member`), or
  `nil` when they are in none of them.
  """
  @spec role_in_any(t(), [binary()]) :: team_role() | nil
  def role_in_any(%__MODULE__{} = scope, team_ids) do
    team_ids
    |> Enum.map(&team_role(scope, &1))
    |> Enum.reject(&is_nil/1)
    |> Enum.min_by(&rank/1, fn -> nil end)
  end

  @doc "The `team_settings` of one of the caller's teams, or `nil`."
  @spec team_settings(t(), binary()) :: struct() | map() | nil
  def team_settings(%__MODULE__{roles: %{team_settings: settings}}, team_id),
    do: Map.get(settings, team_id)

  def team_settings(%__MODULE__{}, _team_id), do: nil

  defp rank(:lead), do: 0
  defp rank(:member), do: 1
end
