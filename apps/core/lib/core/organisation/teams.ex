defmodule Core.Organisation.Teams do
  @moduledoc """
  Teams, their members and their settings (JH-01 §4.2, §6.2).

  Two guards, tested: **a team keeps at least one lead or manager while it
  has members**, and **a lead changes no role above lead** (`:role_above_yours`:
  "Only a manager can make a manager."). An admin may do anything; a manager
  anything in their teams; a lead invites, changes roles and removes within
  their team; a member reads.
  """

  alias Core.Access
  alias Core.Audit
  alias Data.Accounts
  alias Data.Repo
  alias Data.Scope
  alias Data.Teams
  alias Data.Teams.Team
  alias Data.Teams.TeamMember
  alias Data.Teams.TeamSettings

  @team_fields ~w(name slug archived_at)a

  # ── Teams ───────────────────────────────────────────────────────────────────

  @doc "`GET /teams`: every team for an admin or a manager, the caller's own otherwise."
  @spec list(Scope.t()) :: {:ok, [Team.t()]}
  def list(%Scope{organisation: organisation} = scope) do
    teams =
      if Scope.admin?(scope) or Scope.any_team?(scope, :manager),
        do: Teams.list(organisation.id),
        else: Teams.list(organisation.id, ids: Scope.team_ids(scope))

    {:ok, Teams.with_member_counts(teams)}
  end

  @doc "`GET /teams/:id`, with its member count."
  @spec get(Scope.t(), binary()) :: {:ok, Team.t()} | {:error, term()}
  def get(%Scope{} = scope, id) do
    with {:ok, team} <- fetch(scope, :read, id), do: {:ok, counted(team)}
  end

  # Every team a route answers carries `member_count`.
  defp counted(%Team{} = team), do: hd(Teams.with_member_counts([team]))

  defp fetch(%Scope{organisation: organisation} = scope, action, id) do
    with %Team{} = team <- Teams.get(organisation.id, id) || {:error, :not_found},
         :ok <- Access.why_not(scope, action, {:team, team}) do
      {:ok, team}
    end
  end

  @doc "`POST /teams {name}`."
  @spec create(Scope.t(), map()) :: {:ok, Team.t()} | {:error, term()}
  def create(%Scope{organisation: organisation} = scope, params) do
    with :ok <- Access.why_not(scope, :create, {:team, %{}}) do
      attrs = params |> take(~w(name slug)) |> Map.put("organisation_id", organisation.id)
      Repo.transaction(fn -> insert_team(scope, attrs) end)
    end
  end

  defp insert_team(scope, attrs) do
    with {:ok, team} <- Teams.create(attrs),
         {:ok, _settings} <- Teams.put_settings(team.id, %{}) do
      {:ok, _event} = Audit.record(scope, "created", team, after: snapshot(team))
      counted(team)
    else
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  @doc "`PATCH /teams/:id {name}`."
  @spec update(Scope.t(), binary(), map()) :: {:ok, Team.t()} | {:error, term()}
  def update(%Scope{} = scope, id, params) do
    with {:ok, team} <- fetch(scope, :update, id) do
      Repo.transaction(fn -> write_team(scope, team, take(params, ~w(name slug))) end)
    end
  end

  defp write_team(scope, team, attrs) do
    case Teams.update(team, attrs) do
      {:ok, updated} ->
        {:ok, _event} =
          Audit.record(scope, "updated", updated,
            before: snapshot(team),
            after: snapshot(updated)
          )

        counted(updated)

      {:error, changeset} ->
        Repo.rollback(changeset)
    end
  end

  @doc "`POST /teams/:id/archive`."
  @spec archive(Scope.t(), binary(), DateTime.t()) :: {:ok, Team.t()} | {:error, term()}
  def archive(%Scope{} = scope, id, %DateTime{} = now) do
    with {:ok, team} <- fetch(scope, :archive, id) do
      Repo.transaction(fn ->
        {:ok, archived} = Teams.archive(team, now)

        {:ok, _event} =
          Audit.record(scope, "archived", archived,
            before: snapshot(team),
            after: snapshot(archived),
            now: now
          )

        counted(archived)
      end)
    end
  end

  # ── Settings ────────────────────────────────────────────────────────────────

  @doc "`GET /teams/:id/settings`: the six toggles, for a lead or above."
  @spec get_settings(Scope.t(), binary()) :: {:ok, TeamSettings.t()} | {:error, term()}
  def get_settings(%Scope{} = scope, id) do
    with {:ok, team} <- fetch(scope, :read_settings, id), do: {:ok, Teams.get_settings(team.id)}
  end

  @doc "`PUT /teams/:id/settings`."
  @spec put_settings(Scope.t(), binary(), map()) :: {:ok, TeamSettings.t()} | {:error, term()}
  def put_settings(%Scope{} = scope, id, params) do
    with {:ok, team} <- fetch(scope, :update_settings, id) do
      attrs = take(params, Enum.map(TeamSettings.fields(), &to_string/1))
      Repo.transaction(fn -> write_settings(scope, team, attrs) end)
    end
  end

  defp write_settings(scope, team, attrs) do
    fields = TeamSettings.fields()
    before = Audit.snapshot(Teams.get_settings(team.id), fields)

    case Teams.put_settings(team.id, attrs) do
      {:ok, settings} ->
        after_map = settings |> Audit.snapshot(fields) |> Map.put("team_id", team.id)
        {:ok, _event} = Audit.record(scope, "updated", settings, before: before, after: after_map)
        settings

      {:error, changeset} ->
        Repo.rollback(changeset)
    end
  end

  # ── Members ─────────────────────────────────────────────────────────────────

  @doc "`GET /teams/:id/members`: the open memberships with their people."
  @spec list_members(Scope.t(), binary()) :: {:ok, [TeamMember.t()]} | {:error, term()}
  def list_members(%Scope{} = scope, id) do
    with {:ok, team} <- fetch(scope, :list_members, id), do: {:ok, Teams.list_members(team.id)}
  end

  @doc """
  Puts somebody in a team as `role`. **Not a route**: a person joins by
  accepting an invitation (`Core.Organisation.Invitations.accept/3`), which
  calls this inside its transaction. An open membership is kept as it is.
  """
  @spec add_member(Scope.t(), Team.t(), struct(), atom(), DateTime.t()) ::
          {:ok, TeamMember.t()} | {:error, term()}
  def add_member(%Scope{} = scope, %Team{} = team, user, role, %DateTime{} = now) do
    case Teams.get_open_member(team.id, user.id) do
      %TeamMember{} = member ->
        {:ok, member}

      nil ->
        with {:ok, member} <-
               Teams.add_member(%{team_id: team.id, user_id: user.id, role: role, joined_at: now}) do
          {:ok, _event} =
            Audit.record(scope, "joined", member, after: member_snapshot(member), now: now)

          {:ok, %{member | user: Accounts.with_person(user), team: team}}
        end
    end
  end

  @doc """
  `POST /teams/:id/members/:user_id/role {role}`. A lead may not make a
  manager, nor touch one (`:role_above_yours`); the team keeps a lead.
  """
  @spec change_role(Scope.t(), binary(), binary(), String.t() | atom()) ::
          {:ok, TeamMember.t()} | {:error, term()}
  def change_role(%Scope{} = scope, team_id, user_id, role) do
    with {:ok, team} <- fetch(scope, :change_role, team_id),
         {:ok, role} <- role(role),
         %TeamMember{} = member <- Teams.get_open_member(team.id, user_id) || {:error, :not_found},
         :ok <- within_reach(scope, team, member.role),
         :ok <- within_reach(scope, team, role),
         :ok <- keeps_a_lead(team, member, role) do
      Repo.transaction(fn ->
        {:ok, changed} = Teams.change_role(member, role)

        {:ok, _event} =
          Audit.record(scope, "role_changed", changed,
            before: member_snapshot(member),
            after: member_snapshot(changed)
          )

        %{changed | user: member.user, team: team}
      end)
    end
  end

  @doc "`DELETE /teams/:id/members/:user_id`: the membership ends (`left_at`); the row stays."
  @spec remove_member(Scope.t(), binary(), binary(), DateTime.t()) :: :ok | {:error, term()}
  def remove_member(%Scope{} = scope, team_id, user_id, %DateTime{} = now) do
    with {:ok, team} <- fetch(scope, :remove_member, team_id),
         %TeamMember{} = member <- Teams.get_open_member(team.id, user_id) || {:error, :not_found},
         :ok <- within_reach(scope, team, member.role),
         :ok <- keeps_a_lead(team, member, nil) do
      Repo.transaction(fn ->
        {:ok, left} = Teams.leave(member, now)

        {:ok, _event} =
          Audit.record(scope, "removed", left, before: member_snapshot(member), now: now)

        :ok
      end)
      |> elem(1)
    end
  end

  defp role(role) when is_atom(role) and role in [:manager, :lead, :member], do: {:ok, role}

  defp role(role) when is_binary(role) do
    if role in Data.Vocabulary.team_member_roles(),
      do: {:ok, String.to_existing_atom(role)},
      else: {:error, {:missing, :role}}
  end

  defp role(_role), do: {:error, {:missing, :role}}

  # A lead's reach ends at lead: a manager is above them, to make or to touch.
  defp within_reach(scope, team, role) do
    lead? = not Scope.admin?(scope) and Scope.team_role(scope, team.id) == :lead

    if lead? and role == :manager, do: {:error, :role_above_yours}, else: :ok
  end

  # The team keeps a lead or a manager while it has members. `new_role` is
  # nil for a removal.
  defp keeps_a_lead(team, member, new_role) do
    others = team.id |> Teams.list_members() |> Enum.reject(&(&1.id == member.id))
    stays? = others == [] and is_nil(new_role)

    led? =
      Enum.any?(others, &TeamMember.leads?(&1.role)) or (new_role && TeamMember.leads?(new_role))

    if stays? or led?,
      do: :ok,
      else:
        {:error,
         {:forbidden,
          "The team needs a lead or a manager while it has members. Promote someone first."}}
  end

  defp take(params, keys),
    do: params |> Map.new(fn {k, v} -> {to_string(k), v} end) |> Map.take(keys)

  defp snapshot(team), do: Audit.snapshot(team, @team_fields)

  defp member_snapshot(member),
    do: %{
      "team_id" => member.team_id,
      "user_id" => member.user_id,
      "role" => to_string(member.role)
    }
end
