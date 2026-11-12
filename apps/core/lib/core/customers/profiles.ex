defmodule Core.Customers.Profiles do
  @moduledoc """
  Profiles (AQ-01 §4.3, §6.2, §6.3): one way of marketing a customer.

  **The pitch and the facts are two verbs** (QP1-7, PLAN Q28):
  `update_pitch/3` for title, headline and summary — a team lead's, the system
  admin's or the customer's — and `update_facts/3` for the rest, which a
  member may change too. `split/1` sorts a `PATCH` body into one or the
  other; a body that mixes them is refused (`validation_failed`), so a
  member's edit never carries a pitch change in by the side door.

  The same verbs serve the console and the portal: the customer's scope
  reaches their own profiles by the matrix.
  """

  alias Core.Access
  alias Core.Audit
  alias Core.Customers
  alias Data.Channels
  alias Data.Customers.Profile
  alias Data.Profiles, as: Store
  alias Data.Scope
  alias Data.Skills
  alias Data.Teams

  @fields Profile.pitch_fields() ++ Profile.facts_fields() ++ [:customer_id, :archived_at]
  @pitch Enum.map(Profile.pitch_fields(), &to_string/1)
  @facts Enum.map(Profile.facts_fields(), &to_string/1)

  # ── Reads ───────────────────────────────────────────────────────────────────

  @doc "`GET /customers/:id/profiles`, and the portal's `GET /profiles` with the scope's own id."
  @spec list(Scope.t(), binary()) :: {:ok, [Profile.t()]} | {:error, term()}
  def list(%Scope{} = scope, customer_id) do
    with {:ok, customer} <- Customers.fetch(scope, :read, customer_id),
         do: {:ok, Store.list(customer.id)}
  end

  @doc "`GET /profiles/:id`."
  @spec get(Scope.t(), binary()) :: {:ok, Profile.t()} | {:error, term()}
  def get(%Scope{} = scope, id), do: fetch(scope, :read, id)

  @doc "The profile behind `id`, if the caller may take `action` on it."
  @spec fetch(Scope.t(), atom(), binary()) :: {:ok, Profile.t()} | {:error, term()}
  def fetch(%Scope{organisation: organisation} = scope, action, id) do
    with %Profile{} = profile <- Store.get(id) || {:error, :not_found},
         true <- profile.customer.organisation_id == organisation.id || {:error, :not_found},
         :ok <- Access.why_not(scope, action, {:profile, profile}) do
      {:ok, profile}
    end
  end

  # ── Writes ──────────────────────────────────────────────────────────────────

  @doc "`POST /customers/:id/profiles`: the pitch and the facts together; `owner_ids?` too."
  @spec create(Scope.t(), binary(), map(), DateTime.t()) :: {:ok, Profile.t()} | {:error, term()}
  def create(%Scope{} = scope, customer_id, params, %DateTime{} = now) do
    params = Customers.stringify(params)

    with {:ok, customer} <- Customers.fetch(scope, :read, customer_id),
         :ok <- Access.why_not(scope, :create, {:profile, %{customer: customer}}),
         {:ok, owners} <- owners(scope, customer, params["owner_ids"]) do
      attrs = params |> Map.take(@pitch ++ @facts) |> Map.put("customer_id", customer.id)

      Customers.commit(fn ->
        insert(scope, attrs, owners, Customers.today(customer, now), now)
      end)
    end
  end

  defp insert(scope, attrs, owners, since, now) do
    with {:ok, profile} <- Store.create(attrs),
         :ok <- Store.put_owners(profile, owners, since) do
      {:ok, _event} = Audit.record(scope, "created", profile, after: snapshot(profile), now: now)
      {:ok, Store.reload(profile)}
    end
  end

  @doc """
  Sorts a `PATCH /profiles/:id` body: `{:pitch, attrs}`, `{:facts, attrs}`,
  or `{:error, {:invalid, details}}` when it mixes the two or names nothing.
  """
  @spec split(map()) :: {:pitch, map()} | {:facts, map()} | {:error, term()}
  def split(params) do
    params = Customers.stringify(params)
    pitch = Map.take(params, @pitch)
    facts = Map.take(params, @facts)

    case {map_size(pitch), map_size(facts)} do
      {0, 0} ->
        {:error, {:missing, :fields}}

      {_some, 0} ->
        {:pitch, pitch}

      {0, _some} ->
        {:facts, facts}

      _mixed ->
        {:error,
         {:invalid,
          Map.new(Map.keys(pitch), &{&1, ["belongs to the pitch; send the pitch on its own"]})}}
    end
  end

  @doc """
  `PATCH /profiles/:id`: the body sorted by `split/1` and routed to
  `update_pitch/3` or `update_facts/3`; a mixed body is refused. The
  controllers call this so the rule sits in one place for both apps.
  """
  @spec update(Scope.t(), binary(), map()) :: {:ok, Profile.t()} | {:error, term()}
  def update(%Scope{} = scope, id, params) do
    case split(params) do
      {:pitch, attrs} -> update_pitch(scope, id, attrs)
      {:facts, attrs} -> update_facts(scope, id, attrs)
      {:error, _reason} = refusal -> refusal
    end
  end

  @doc "`PATCH /profiles/:id` with only pitch fields: title, headline, summary."
  @spec update_pitch(Scope.t(), binary(), map()) :: {:ok, Profile.t()} | {:error, term()}
  def update_pitch(%Scope{} = scope, id, params) do
    attrs = Map.take(Customers.stringify(params), @pitch)
    write(scope, :update_pitch, id, attrs, &Store.update_pitch/2)
  end

  @doc "`PATCH /profiles/:id` with only facts: skills' companions, targets, availability, the money floor."
  @spec update_facts(Scope.t(), binary(), map()) :: {:ok, Profile.t()} | {:error, term()}
  def update_facts(%Scope{} = scope, id, params) do
    attrs = Map.take(Customers.stringify(params), @facts)
    write(scope, :update_facts, id, attrs, &Store.update_facts/2)
  end

  @doc """
  The pitch write itself, with its audit row, for a caller that has decided
  it may: `update_pitch/3` above, and an approved `profile_change` on its
  requester's behalf (AQ-07 §7, QP7-15) — the member still can't edit the
  pitch directly.
  """
  @spec write_pitch(Scope.t(), Profile.t(), map()) :: {:ok, Profile.t()} | {:error, term()}
  def write_pitch(%Scope{} = scope, %Profile{} = profile, params) do
    attrs = Map.take(Customers.stringify(params), @pitch)

    Customers.commit(fn ->
      record(scope, "update_pitch", profile, Store.update_pitch(profile, attrs))
    end)
  end

  defp write(scope, action, id, attrs, store) do
    with {:ok, profile} <- fetch(scope, action, id) do
      Customers.commit(fn ->
        record(scope, to_string(action), profile, store.(profile, attrs))
      end)
    end
  end

  # The audit row for a profile write, before → after, and the profile fresh.
  defp record(scope, action, profile, {:ok, updated}) do
    {:ok, _event} =
      Audit.record(scope, action, updated, before: snapshot(profile), after: snapshot(updated))

    {:ok, Store.reload(updated)}
  end

  defp record(_scope, _action, _profile, {:error, _changeset} = error), do: error

  @doc "`POST /profiles/:id/archive`."
  @spec archive(Scope.t(), binary(), DateTime.t()) :: {:ok, Profile.t()} | {:error, term()}
  def archive(%Scope{} = scope, id, %DateTime{} = now) do
    with {:ok, profile} <- fetch(scope, :archive, id) do
      Customers.commit(fn ->
        {:ok, archived} = Store.archive(profile, now)

        {:ok, _event} =
          Audit.record(scope, "archived", archived,
            before: snapshot(profile),
            after: snapshot(archived),
            now: now
          )

        {:ok, Store.reload(archived)}
      end)
    end
  end

  @doc "`PUT /profiles/:id/owners {user_ids}`: staff of a team serving the customer."
  @spec put_owners(Scope.t(), binary(), [binary()], DateTime.t()) ::
          {:ok, Profile.t()} | {:error, term()}
  def put_owners(%Scope{} = scope, id, user_ids, %DateTime{} = now) do
    with {:ok, profile} <- fetch(scope, :set_owners, id),
         {:ok, owners} <- owners(scope, profile.customer, user_ids) do
      before = %{"user_ids" => Enum.map(profile.profile_members, & &1.user_id)}
      since = Customers.today(profile.customer, now)

      store = fn -> Store.put_owners(profile, owners, since) end

      Customers.commit(fn ->
        replace(scope, "owners_set", profile, before, %{"user_ids" => owners}, store)
      end)
    end
  end

  # An owner is somebody in a team serving the customer (any team, for a
  # customer in none). Anyone else is `:not_found`: the caller may not know
  # the account exists.
  defp owners(_scope, _customer, nil), do: {:ok, []}

  defp owners(%Scope{organisation: organisation}, customer, user_ids) when is_list(user_ids) do
    team_ids =
      if customer.team_ids == [],
        do: organisation.id |> Teams.list() |> Enum.map(& &1.id),
        else: customer.team_ids

    staff = team_ids |> Teams.memberships_in() |> Enum.map(& &1.user_id) |> Enum.uniq()
    wanted = user_ids |> Enum.map(&to_string/1) |> Enum.uniq()

    if Enum.all?(wanted, &(&1 in staff)), do: {:ok, wanted}, else: {:error, :not_found}
  end

  defp owners(_scope, _customer, _not_a_list), do: {:error, {:missing, :user_ids}}

  @doc "`PUT /profiles/:id/skills [{skill_id, level, years}]`: a fact, so a member and the customer may."
  @spec put_skills(Scope.t(), binary(), [map()]) :: {:ok, Profile.t()} | {:error, term()}
  def put_skills(%Scope{organisation: organisation} = scope, id, rows) when is_list(rows) do
    with {:ok, profile} <- fetch(scope, :update_facts, id),
         {:ok, rows} <- known_skills(organisation.id, rows),
         do: write_skills(scope, profile, rows)
  end

  def put_skills(_scope, _id, _rows), do: {:error, {:missing, :skills}}

  @doc """
  The skills write itself (`[%{"skill_id", "level", "years"}]`, known
  skills), with its audit row, for a caller that has decided it may:
  `put_skills/3` above, and an approved `profile_change` (AQ-07 §7).
  """
  @spec write_skills(Scope.t(), Profile.t(), [map()]) :: {:ok, Profile.t()} | {:error, term()}
  def write_skills(%Scope{} = scope, %Profile{} = profile, rows) do
    before = %{
      "skills" =>
        Enum.map(
          profile.profile_skills,
          &%{"skill_id" => &1.skill_id, "level" => to_string(&1.level)}
        )
    }

    store = fn -> Store.put_skills(profile, rows) end

    Customers.commit(fn ->
      replace(scope, "skills_set", profile, before, %{"skills" => rows}, store)
    end)
  end

  defp known_skills(organisation_id, rows) do
    rows = Enum.map(rows, &Customers.stringify/1)
    ids = rows |> Enum.map(& &1["skill_id"]) |> Enum.reject(&is_nil/1)
    known = organisation_id |> Skills.list(ids: ids, include_archived: true) |> Enum.map(& &1.id)

    if length(ids) == length(rows) and Enum.all?(ids, &(&1 in known)),
      do: {:ok, Enum.map(rows, &Map.take(&1, ~w(skill_id level years)))},
      else: {:error, {:missing, :skill_id}}
  end

  @doc "`PUT /profiles/:id/channels {channel_ids}`: the customer's own live channels only."
  @spec put_channels(Scope.t(), binary(), [binary()]) :: {:ok, Profile.t()} | {:error, term()}
  def put_channels(%Scope{} = scope, id, channel_ids) when is_list(channel_ids) do
    with {:ok, profile} <- fetch(scope, :update_facts, id),
         {:ok, ids} <- own_channels(profile, channel_ids) do
      before = %{"channel_ids" => Enum.map(profile.profile_channels, & &1.channel_id)}

      store = fn -> Store.put_channels(profile, ids) end

      Customers.commit(fn ->
        replace(scope, "channels_set", profile, before, %{"channel_ids" => ids}, store)
      end)
    end
  end

  def put_channels(_scope, _id, _ids), do: {:error, {:missing, :channel_ids}}

  defp own_channels(profile, channel_ids) do
    wanted = channel_ids |> Enum.map(&to_string/1) |> Enum.uniq()
    live = Channels.live_ids(profile.customer_id, Enum.filter(wanted, &uuid?/1))
    if Enum.all?(wanted, &(&1 in live)), do: {:ok, wanted}, else: {:error, :not_found}
  end

  # A set of links replaced (`store` answers `:ok` or a changeset error), then
  # the audit row with the ids before and after, and the profile fresh.
  defp replace(scope, action, profile, before, after_map, store) do
    with :ok <- store.() do
      {:ok, _event} = Audit.record(scope, action, profile, before: before, after: after_map)
      {:ok, Store.reload(profile)}
    end
  end

  defp uuid?(value), do: match?({:ok, _uuid}, Ecto.UUID.cast(value))

  defp snapshot(profile), do: Audit.snapshot(profile, @fields)
end
