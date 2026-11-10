defmodule Core.Organisation do
  @moduledoc """
  The organisation (JH-01 P1.1): bootstrap, its settings, its admins, the
  staff list and the audit log. Teams are `Core.Organisation.Teams`,
  invitations `Core.Organisation.Invitations`.

  Every write records an audit row inside its transaction (`Core.Audit`).
  Every function takes a `%Data.Scope{}` first and asks `Core.Access` before
  acting; a row the caller may not know exists is `:not_found`.
  """

  alias Core.Access
  alias Core.Audit
  alias Core.Audit.Labels
  alias Core.Organisation.Invitations
  alias Data.Accounts
  alias Data.Organisations
  alias Data.Organisations.OrganisationSettings
  alias Data.Repo
  alias Data.Scope
  alias Data.Seeds.Skills, as: SkillsSeed
  alias Data.Teams

  @org_fields ~w(name slug country_code timezone currency_code)a

  # ── Bootstrap ───────────────────────────────────────────────────────────────

  @doc """
  `mix jh.bootstrap` (§3): the organisation with its default settings and an
  **admin invitation** for the email. Idempotent: run twice, it reports the
  organisation exists and re-issues the invitation if none is open.

  Answers `{:ok, %{organisation, invitation, organisation_created?, invitation: :issued | :reissued | :open}}`.
  """
  @spec bootstrap(map(), DateTime.t()) :: {:ok, map()} | {:error, term()}
  def bootstrap(%{org_name: org_name, admin_email: email, admin_name: name}, %DateTime{} = now) do
    Repo.transaction(fn ->
      {organisation, created?} = find_or_create_organisation(org_name, now)
      scope = Scope.system(organisation)

      case Invitations.issue(scope, %{kind: :admin, email: email, invited_name: name}, now) do
        {:ok, invitation, status} ->
          %{
            organisation: organisation,
            invitation: invitation,
            organisation_created?: created?,
            status: status
          }

        {:error, reason} ->
          Repo.rollback(reason)
      end
    end)
  end

  defp find_or_create_organisation(name, now) do
    case Organisations.the_one() do
      %{} = organisation ->
        {organisation, false}

      nil ->
        {:ok, organisation} = Organisations.create(%{name: name})
        {:ok, _settings} = Organisations.put_settings(organisation.id, %{})
        # The production seed for the one thing the seed cannot make (QP1-4).
        _counts = SkillsSeed.load_for(organisation.id)
        scope = Scope.system(organisation)

        {:ok, _event} =
          Audit.record(scope, "created", organisation,
            after: Audit.snapshot(organisation, @org_fields),
            now: now
          )

        {organisation, true}
    end
  end

  # ── The organisation and its settings ───────────────────────────────────────

  @doc "`GET /org`: the organisation and its timings, for a lead or above."
  @spec get(Scope.t()) ::
          {:ok, %{organisation: struct(), settings: OrganisationSettings.t()}} | {:error, term()}
  def get(%Scope{organisation: organisation} = scope) do
    with :ok <- Access.why_not(scope, :read_settings, {:organisation, organisation}) do
      {:ok, %{organisation: organisation, settings: Organisations.get_settings(organisation.id)}}
    end
  end

  @doc "`PUT /org/settings`: the timings, by an admin. Name, timezone and currency ride along."
  @spec update_settings(Scope.t(), map()) :: {:ok, map()} | {:error, term()}
  def update_settings(%Scope{organisation: organisation} = scope, params) do
    params = Map.new(params, fn {k, v} -> {to_string(k), v} end)
    setting_params = Map.take(params, Enum.map(OrganisationSettings.fields(), &to_string/1))
    org_params = Map.take(params, ~w(name timezone currency_code country_code))

    with :ok <- Access.why_not(scope, :update_settings, {:organisation, organisation}) do
      Repo.transaction(fn -> write_settings(scope, setting_params, org_params) end)
    end
  end

  defp write_settings(%Scope{organisation: organisation} = scope, setting_params, org_params) do
    fields = OrganisationSettings.fields()
    before = Audit.snapshot(Organisations.get_settings(organisation.id), fields)
    org_before = Audit.snapshot(organisation, @org_fields)

    with {:ok, settings} <- Organisations.put_settings(organisation.id, setting_params),
         {:ok, updated} <- Organisations.update(organisation, org_params) do
      {:ok, _event} =
        Audit.record(scope, "updated", settings,
          before: before,
          after: Audit.snapshot(settings, fields)
        )

      record_organisation_change(scope, org_params, org_before, updated)
      %{organisation: updated, settings: settings}
    else
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp record_organisation_change(_scope, org_params, _before, _updated) when org_params == %{},
    do: :ok

  defp record_organisation_change(scope, _org_params, before, updated) do
    {:ok, _event} =
      Audit.record(scope, "updated", updated,
        before: before,
        after: Audit.snapshot(updated, @org_fields)
      )

    :ok
  end

  # ── Admins ──────────────────────────────────────────────────────────────────

  @doc "`GET /org/admins`."
  @spec list_admins(Scope.t()) :: {:ok, [struct()]} | {:error, term()}
  def list_admins(%Scope{organisation: organisation} = scope) do
    with :ok <- Access.why_not(scope, :list_admins, {:organisation, organisation}) do
      {:ok, Organisations.list_admins(organisation.id)}
    end
  end

  @doc "`POST /org/admins {user_id}`: makes a staff account an admin."
  @spec grant_admin(Scope.t(), binary(), DateTime.t()) :: {:ok, struct()} | {:error, term()}
  def grant_admin(%Scope{organisation: organisation} = scope, user_id, %DateTime{} = now) do
    with :ok <- Access.why_not(scope, :grant_admin, {:organisation, organisation}),
         %{} = user <- Accounts.get_user(user_id) || {:error, :not_found},
         :ok <- not_yet_admin(organisation.id, user.id) do
      Repo.transaction(fn ->
        {:ok, admin} =
          Organisations.grant_admin(%{
            organisation_id: organisation.id,
            user_id: user.id,
            granted_at: now,
            granted_by_user_id: Scope.user_id(scope)
          })

        {:ok, _event} =
          Audit.record(scope, "granted", admin, after: %{user_id: user.id}, now: now)

        %{admin | user: user}
      end)
    end
  end

  @doc """
  `DELETE /org/admins/:user_id`. **The last admin cannot be removed**
  (`:last_admin`): "The organisation needs one admin. Grant another first."
  """
  @spec revoke_admin(Scope.t(), binary(), DateTime.t()) :: :ok | {:error, term()}
  def revoke_admin(%Scope{organisation: organisation} = scope, user_id, %DateTime{} = now) do
    with :ok <- Access.why_not(scope, :revoke_admin, {:organisation, organisation}),
         %{} = admin <- Organisations.get_admin(organisation.id, user_id) || {:error, :not_found},
         :ok <- not_the_last(organisation.id) do
      Repo.transaction(fn ->
        {:ok, _gone} = Organisations.revoke_admin(admin)

        {:ok, _event} =
          Audit.record(scope, "revoked", admin, before: %{user_id: user_id}, now: now)

        :ok
      end)
      |> elem(1)
    end
  end

  defp not_yet_admin(organisation_id, user_id) do
    if Organisations.get_admin(organisation_id, user_id), do: {:error, :conflict}, else: :ok
  end

  defp not_the_last(organisation_id) do
    if Organisations.count_admins(organisation_id) > 1, do: :ok, else: {:error, :last_admin}
  end

  # ── People ──────────────────────────────────────────────────────────────────

  @doc """
  `GET /people?team_id`: every staff person the caller may see — all of them
  for an admin, their own teams' for anyone else — with email, teams and
  roles, last signed in, and whether they are an admin.
  """
  @spec list_people(Scope.t(), map()) :: {:ok, [map()]} | {:error, term()}
  def list_people(%Scope{organisation: organisation} = scope, filters \\ %{}) do
    with :ok <- Access.why_not(scope, :read_people, :people) do
      visible = visible_team_ids(scope, filters[:team_id] || filters["team_id"])
      admins = organisation.id |> Organisations.list_admins() |> Map.new(&{&1.user_id, &1})
      memberships = Teams.memberships_in(visible)

      people =
        memberships
        |> Enum.group_by(& &1.user_id)
        |> Enum.map(fn {user_id, rows} ->
          person(hd(rows).user, rows, Map.has_key?(admins, user_id))
        end)
        |> add_admins_without_teams(scope, admins, filters, Enum.map(memberships, & &1.user_id))
        |> Enum.sort_by(& &1.display_name)

      {:ok, people}
    end
  end

  defp visible_team_ids(scope, team_id) do
    all =
      if Scope.admin?(scope),
        do: Enum.map(Teams.list(scope.organisation.id), & &1.id),
        else: Scope.team_ids(scope)

    if team_id, do: Enum.filter(all, &(&1 == team_id)), else: all
  end

  # An admin in no team is still staff: an admin sees them, unless a team
  # filter is on; everyone else sees their own teams and nothing beyond.
  defp add_admins_without_teams(people, scope, admins, filters, seen) do
    if filters[:team_id] || filters["team_id"] || not Scope.admin?(scope) do
      people
    else
      extra =
        for {user_id, admin} <- admins, user_id not in seen, do: person(admin.user, [], true)

      people ++ extra
    end
  end

  defp person(user, memberships, admin?) do
    %{
      user_id: user.id,
      display_name: user.person.display_name,
      email: user.email,
      admin: admin?,
      is_admin: admin?,
      teams: for(m <- memberships, do: %{team_id: m.team_id, name: m.team.name, role: m.role}),
      last_signed_in_at: user.last_signed_in_at,
      suspended_at: user.suspended_at
    }
  end

  # ── The audit log ───────────────────────────────────────────────────────────

  @page 50

  @doc """
  `GET /org/audit?subject_kind&subject_id&actor&from&to&cursor`, newest first,
  keyset. An admin reads everything; a manager reads rows about their teams.
  Answers `{:ok, events, next_cursor}`.
  """
  @spec list_audit(Scope.t(), map()) :: {:ok, [struct()], String.t() | nil} | {:error, term()}
  def list_audit(%Scope{organisation: organisation} = scope, params \\ %{}) do
    with :ok <- Access.why_not(scope, :read_audit, {:organisation, organisation}),
         {:ok, filters} <- audit_filters(scope, params) do
      events = Data.Audit.list(organisation.id, filters, @page + 1)
      {page, more} = Enum.split(events, @page)

      {:ok, Labels.attach(page), if(more == [], do: nil, else: encode_cursor(List.last(page)))}
    end
  end

  defp audit_filters(scope, params) do
    params = Map.new(params, fn {k, v} -> {to_string(k), v} end)

    with {:ok, from} <- time(params["from"]),
         {:ok, to} <- time(params["to"]),
         {:ok, cursor} <- decode_cursor(params["cursor"]) do
      {:ok,
       %{
         subject_kind: params["subject_kind"],
         subject_id: uuid(params["subject_id"]),
         actor_user_id: uuid(params["actor"]),
         from: from,
         to: to,
         cursor: cursor,
         team_ids: if(Scope.admin?(scope), do: nil, else: Scope.team_ids(scope))
       }}
    end
  end

  defp time(nil), do: {:ok, nil}

  defp time(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, at, _offset} -> {:ok, at}
      _invalid -> {:error, {:missing, :from}}
    end
  end

  defp uuid(nil), do: nil

  defp uuid(value) do
    case Ecto.UUID.cast(value) do
      {:ok, id} -> id
      :error -> Ecto.UUID.generate()
    end
  end

  defp encode_cursor(event),
    do: Base.url_encode64("#{DateTime.to_iso8601(event.occurred_at)}|#{event.id}", padding: false)

  defp decode_cursor(nil), do: {:ok, nil}

  defp decode_cursor(cursor) when is_binary(cursor) do
    with {:ok, decoded} <- Base.url_decode64(cursor, padding: false),
         [at, id] <- String.split(decoded, "|", parts: 2),
         {:ok, at, _offset} <- DateTime.from_iso8601(at),
         {:ok, id} <- Ecto.UUID.cast(id) do
      {:ok, {at, id}}
    else
      _invalid -> {:error, {:missing, :cursor}}
    end
  end
end
