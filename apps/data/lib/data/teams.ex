defmodule Data.Teams do
  @moduledoc """
  Teams, their members and their settings (AQ-01 §4.2). Storage only; the
  guards (a team keeps a lead, a lead promotes nobody above lead) are
  `Core.Organisation.Teams`'s.
  """

  import Ecto.Query, warn: false

  alias Data.Repo
  alias Data.Teams.{Team, TeamMember, TeamSettings}

  # ── Teams ───────────────────────────────────────────────────────────────────

  @spec get(binary(), binary()) :: Team.t() | nil
  def get(organisation_id, id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> Repo.get_by(Team, id: uuid, organisation_id: organisation_id)
      :error -> nil
    end
  end

  def get(_organisation_id, _id), do: nil

  @doc "An organisation's teams by name; `ids` narrows to some, `include_archived` keeps the archived."
  @spec list(binary(), keyword()) :: [Team.t()]
  def list(organisation_id, opts \\ []) do
    query = from(t in Team, where: t.organisation_id == ^organisation_id, order_by: [asc: t.name])

    query =
      case Keyword.get(opts, :ids) do
        nil -> query
        ids -> where(query, [t], t.id in ^ids)
      end

    query =
      if Keyword.get(opts, :include_archived, false),
        do: query,
        else: where(query, [t], is_nil(t.archived_at))

    Repo.all(query)
  end

  @doc "Teams by id, as `%{id => team}`."
  @spec by_id([binary()]) :: %{binary() => Team.t()}
  def by_id([]), do: %{}
  def by_id(ids), do: from(t in Team, where: t.id in ^ids) |> Repo.all() |> Map.new(&{&1.id, &1})

  @spec create(map()) :: {:ok, Team.t()} | {:error, Ecto.Changeset.t()}
  def create(attrs), do: %Team{} |> Team.changeset(attrs) |> Repo.insert()

  @spec update(Team.t(), map()) :: {:ok, Team.t()} | {:error, Ecto.Changeset.t()}
  def update(%Team{} = team, attrs), do: team |> Team.changeset(attrs) |> Repo.update()

  @spec archive(Team.t(), DateTime.t()) :: {:ok, Team.t()} | {:error, Ecto.Changeset.t()}
  def archive(%Team{} = team, %DateTime{} = at),
    do: team |> Ecto.Changeset.change(archived_at: at) |> Repo.update()

  # ── Members ─────────────────────────────────────────────────────────────────

  @doc "The open memberships of a team, with users and persons, oldest first."
  @spec list_members(binary()) :: [TeamMember.t()]
  def list_members(team_id) do
    from(m in TeamMember,
      where: m.team_id == ^team_id and is_nil(m.left_at),
      order_by: [asc: m.joined_at],
      preload: [user: :person]
    )
    |> Repo.all()
  end

  @doc "The open memberships of a user across teams, with the teams."
  @spec memberships_of(binary()) :: [TeamMember.t()]
  def memberships_of(user_id) do
    from(m in TeamMember,
      join: t in assoc(m, :team),
      where: m.user_id == ^user_id and is_nil(m.left_at) and is_nil(t.archived_at),
      preload: [team: t]
    )
    |> Repo.all()
  end

  @doc "Every open membership in these teams, with users and persons: the people list."
  @spec memberships_in([binary()]) :: [TeamMember.t()]
  def memberships_in([]), do: []

  def memberships_in(team_ids) do
    from(m in TeamMember,
      where: m.team_id in ^team_ids and is_nil(m.left_at),
      preload: [user: :person, team: []]
    )
    |> Repo.all()
  end

  @spec get_open_member(binary(), binary()) :: TeamMember.t() | nil
  def get_open_member(team_id, user_id) do
    from(m in TeamMember,
      where: m.team_id == ^team_id and m.user_id == ^user_id and is_nil(m.left_at),
      preload: [user: :person]
    )
    |> Repo.one()
  end

  @spec add_member(map()) :: {:ok, TeamMember.t()} | {:error, Ecto.Changeset.t()}
  def add_member(attrs), do: %TeamMember{} |> TeamMember.changeset(attrs) |> Repo.insert()

  @spec change_role(TeamMember.t(), atom() | String.t()) ::
          {:ok, TeamMember.t()} | {:error, Ecto.Changeset.t()}
  def change_role(%TeamMember{} = member, role),
    do: member |> TeamMember.changeset(%{role: role}) |> Repo.update()

  @spec leave(TeamMember.t(), DateTime.t()) ::
          {:ok, TeamMember.t()} | {:error, Ecto.Changeset.t()}
  def leave(%TeamMember{} = member, %DateTime{} = at),
    do: member |> Ecto.Changeset.change(left_at: at) |> Repo.update()

  # ── Settings ────────────────────────────────────────────────────────────────

  @doc "The row, or the code defaults when there is none."
  @spec get_settings(binary()) :: TeamSettings.t()
  def get_settings(team_id), do: Repo.get(TeamSettings, team_id) || TeamSettings.defaults(team_id)

  @doc "The settings of several teams at once, as `%{team_id => settings}`, code defaults for the unwritten."
  @spec settings_for([binary()]) :: %{binary() => TeamSettings.t()}
  def settings_for([]), do: %{}

  def settings_for(team_ids) do
    written =
      from(s in TeamSettings, where: s.team_id in ^team_ids)
      |> Repo.all()
      |> Map.new(&{&1.team_id, &1})

    Map.new(team_ids, &{&1, Map.get(written, &1) || TeamSettings.defaults(&1)})
  end

  @doc "The teams with `member_count` filled from the open memberships."
  @spec with_member_counts([Team.t()]) :: [Team.t()]
  def with_member_counts(teams) do
    counts = teams |> Enum.map(& &1.id) |> member_counts()
    Enum.map(teams, &%{&1 | member_count: Map.get(counts, &1.id, 0)})
  end

  @doc "How many open members each team has, as `%{team_id => count}`."
  @spec member_counts([binary()]) :: %{binary() => non_neg_integer()}
  def member_counts([]), do: %{}

  def member_counts(team_ids) do
    from(m in TeamMember,
      where: m.team_id in ^team_ids and is_nil(m.left_at),
      group_by: m.team_id,
      select: {m.team_id, count(m.id)}
    )
    |> Repo.all()
    |> Map.new()
  end

  @doc "Writes the settings, creating the row on first write."
  @spec put_settings(binary(), map()) :: {:ok, TeamSettings.t()} | {:error, Ecto.Changeset.t()}
  def put_settings(team_id, attrs) do
    attrs = Map.new(attrs, fn {k, v} -> {to_string(k), v} end)

    case Repo.get(TeamSettings, team_id) do
      nil ->
        %TeamSettings{}
        |> TeamSettings.changeset(Map.put(attrs, "team_id", team_id))
        |> Repo.insert()

      row ->
        row |> TeamSettings.changeset(attrs) |> Repo.update()
    end
  end
end
