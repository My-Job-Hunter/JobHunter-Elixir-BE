defmodule Data.Profiles do
  @moduledoc """
  Profiles with their owners, skills, channel links and default document
  (AQ-01 §4.3). Storage only. Every read answers the profile **with its
  customer, and the customer with `team_ids`**, because `Core.Access`
  decides from the customer and a profile is never shown without one.
  """

  import Ecto.Query, warn: false

  alias Data.Customers
  alias Data.Customers.{Profile, ProfileChannel, ProfileDefaultDocument, ProfileMember}
  alias Data.Customers.ProfileSkill
  alias Data.Repo

  @preload [
    :default_document_link,
    :profile_channels,
    customer: [:customer_teams],
    profile_members: [user: :person],
    profile_skills: [:skill]
  ]

  @doc "A profile by id, with everything a screen shows; `nil` for a malformed or unknown id."
  @spec get(binary()) :: Profile.t() | nil
  def get(id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> Profile |> Repo.get(uuid) |> Repo.preload(@preload) |> fill()
      :error -> nil
    end
  end

  def get(_id), do: nil

  @doc "A customer's live profiles by title; `include_archived` keeps the archived."
  @spec list(binary(), keyword()) :: [Profile.t()]
  def list(customer_id, opts \\ []) do
    query =
      from(p in Profile,
        where: p.customer_id == ^customer_id,
        order_by: [asc: p.title],
        preload: ^@preload
      )

    query =
      if Keyword.get(opts, :include_archived, false),
        do: query,
        else: where(query, [p], is_nil(p.archived_at))

    query |> Repo.all() |> Enum.map(&fill/1)
  end

  @doc """
  The organisation's live profiles — not archived, active, of a customer
  not archived — with their customers and skills: whom a job may suit
  (AQ-03 §9).
  """
  @spec live_in_organisation(binary()) :: [Profile.t()]
  def live_in_organisation(organisation_id) do
    from(p in Profile,
      join: c in assoc(p, :customer),
      where:
        c.organisation_id == ^organisation_id and is_nil(c.archived_at) and
          is_nil(p.archived_at) and p.status == :active,
      order_by: [asc: c.display_name, asc: p.title],
      preload: ^@preload
    )
    |> Repo.all()
    |> Enum.map(&fill/1)
  end

  @doc "The profile again, with every association fresh."
  @spec reload(Profile.t()) :: Profile.t()
  def reload(%Profile{id: id}), do: get(id)

  defp fill(nil), do: nil
  defp fill(%Profile{} = profile), do: %{profile | customer: Customers.fill(profile.customer)}

  # ── Writes ──────────────────────────────────────────────────────────────────

  @spec create(map()) :: {:ok, Profile.t()} | {:error, Ecto.Changeset.t()}
  def create(attrs) do
    with {:ok, profile} <- %Profile{} |> Profile.create_changeset(attrs) |> Repo.insert() do
      {:ok, reload(profile)}
    end
  end

  @spec update_pitch(Profile.t(), map()) :: {:ok, Profile.t()} | {:error, Ecto.Changeset.t()}
  def update_pitch(%Profile{} = profile, attrs),
    do: profile |> Profile.pitch_changeset(attrs) |> Repo.update()

  @spec update_facts(Profile.t(), map()) :: {:ok, Profile.t()} | {:error, Ecto.Changeset.t()}
  def update_facts(%Profile{} = profile, attrs),
    do: profile |> Profile.facts_changeset(attrs) |> Repo.update()

  @spec archive(Profile.t(), DateTime.t()) :: {:ok, Profile.t()} | {:error, Ecto.Changeset.t()}
  def archive(%Profile{} = profile, %DateTime{} = at),
    do: profile |> Ecto.Changeset.change(archived_at: at) |> Repo.update()

  # ── Owners, skills, channels: replaced as a set ─────────────────────────────

  @doc "The owners become exactly `user_ids`: new ones added from `since`, the rest kept, others removed."
  @spec put_owners(Profile.t(), [binary()], Date.t()) :: :ok | {:error, Ecto.Changeset.t()}
  def put_owners(%Profile{} = profile, user_ids, %Date{} = since) do
    replace_links(
      profile,
      ProfileMember,
      :user_id,
      user_ids,
      &%{profile_id: profile.id, user_id: &1, since_on: since}
    )
  end

  @doc "The skills become exactly `rows` (`%{skill_id, level, years}`); a changed level is rewritten."
  @spec put_skills(Profile.t(), [map()]) :: :ok | {:error, Ecto.Changeset.t()}
  def put_skills(%Profile{} = profile, rows) do
    Repo.delete_all(from(s in ProfileSkill, where: s.profile_id == ^profile.id))

    Enum.reduce_while(rows, :ok, fn row, :ok ->
      attrs =
        row |> Map.new(fn {k, v} -> {to_string(k), v} end) |> Map.put("profile_id", profile.id)

      case %ProfileSkill{} |> ProfileSkill.changeset(attrs) |> Repo.insert() do
        {:ok, _link} -> {:cont, :ok}
        {:error, changeset} -> {:halt, {:error, changeset}}
      end
    end)
  end

  @doc "The linked channels become exactly `channel_ids`."
  @spec put_channels(Profile.t(), [binary()]) :: :ok | {:error, Ecto.Changeset.t()}
  def put_channels(%Profile{} = profile, channel_ids) do
    replace_links(
      profile,
      ProfileChannel,
      :channel_id,
      channel_ids,
      &%{profile_id: profile.id, channel_id: &1}
    )
  end

  defp replace_links(profile, schema, key, wanted, attrs_for) do
    current =
      from(l in schema, where: l.profile_id == ^profile.id, select: field(l, ^key)) |> Repo.all()

    gone = current -- wanted
    new = wanted -- current

    if gone != [] do
      Repo.delete_all(
        from(l in schema, where: l.profile_id == ^profile.id and field(l, ^key) in ^gone)
      )
    end

    Enum.reduce_while(new, :ok, fn id, :ok ->
      case struct(schema) |> schema.changeset(attrs_for.(id)) |> Repo.insert() do
        {:ok, _link} -> {:cont, :ok}
        {:error, changeset} -> {:halt, {:error, changeset}}
      end
    end)
  end

  @doc "Makes `document_id` the profile's default, replacing the previous one."
  @spec put_default_document(Profile.t(), binary()) ::
          {:ok, ProfileDefaultDocument.t()} | {:error, Ecto.Changeset.t()}
  def put_default_document(%Profile{} = profile, document_id) do
    attrs = %{profile_id: profile.id, document_id: document_id}

    case Repo.get_by(ProfileDefaultDocument, profile_id: profile.id) do
      nil -> %ProfileDefaultDocument{} |> ProfileDefaultDocument.changeset(attrs) |> Repo.insert()
      link -> link |> ProfileDefaultDocument.changeset(attrs) |> Repo.update()
    end
  end

  @doc "The profiles a staff account owns, with their customers: the portal's `/team` and the console's `mine`."
  @spec owned_by(binary()) :: [Profile.t()]
  def owned_by(user_id) do
    from(p in Profile,
      join: m in assoc(p, :profile_members),
      where: m.user_id == ^user_id and is_nil(p.archived_at),
      preload: ^@preload
    )
    |> Repo.all()
    |> Enum.map(&fill/1)
  end
end
