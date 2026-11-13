defmodule Data.Meetings do
  @moduledoc """
  Meetings and their attendees (AQ-06 §5.3). Storage only: who may see or
  move one is `Core.Access`'s, the verbs, the clash and the reminders
  `Core.Meetings`'. Every read is the organisation's.
  """

  import Ecto.Query, warn: false

  alias Data.Leads.Lead
  alias Data.Meetings.{Attendee, Meeting}
  alias Data.Repo

  @doc "What every meeting read carries: its lead (as a card reads it) and its attendees."
  def preload do
    [
      lead: Data.Leads.base_preload(),
      attendees: [:contact, user: [person: :photo]],
      from_message: :conversation
    ]
  end

  @doc "A meeting of the organisation; `nil` otherwise."
  @spec get(binary(), term()) :: Meeting.t() | nil
  def get(organisation_id, id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> Meeting |> Repo.get_by(id: uuid, organisation_id: organisation_id) |> load()
      :error -> nil
    end
  end

  def get(_organisation_id, _id), do: nil

  @doc "The meeting again, fresh."
  @spec reload(Meeting.t()) :: Meeting.t()
  def reload(%Meeting{} = m), do: get(m.organisation_id, m.id)

  @doc "A lead's meetings, by start."
  @spec for_lead(binary()) :: [Meeting.t()]
  def for_lead(lead_id) do
    from(m in Meeting, where: m.lead_id == ^lead_id, order_by: [asc: m.starts_at, asc: m.id])
    |> load_all()
  end

  @doc """
  The meetings of a team's leads (`team_id`) or a customer's
  (`customer_id`): between `from` and `to` by start when given, else every
  scheduled (or proposed, AQ-09) one that has not ended by `now`. By start.
  """
  @spec list(keyword()) :: [Meeting.t()]
  def list(opts) do
    from(m in Meeting,
      join: l in Lead,
      on: l.id == m.lead_id,
      as: :lead,
      join: j in assoc(l, :job),
      as: :job,
      join: p in assoc(l, :profile),
      as: :profile,
      order_by: [asc: m.starts_at, asc: m.id],
      limit: 500
    )
    |> narrow(opts)
    |> window(opts[:from], opts[:to], opts[:now])
    |> load_all()
  end

  defp narrow(query, opts) do
    cond do
      opts[:team_id] -> where(query, [job: j], j.team_id == ^opts[:team_id])
      opts[:customer_id] -> where(query, [profile: p], p.customer_id == ^opts[:customer_id])
      true -> where(query, false)
    end
  end

  defp window(query, nil, nil, %DateTime{} = now),
    do: where(query, [m], m.status in [:scheduled, :proposed] and m.ends_at > ^now)

  defp window(query, from, to, _now) do
    query
    |> then(&if(from, do: where(&1, [m], m.starts_at >= ^from), else: &1))
    |> then(&if(to, do: where(&1, [m], m.starts_at < ^to), else: &1))
  end

  @doc """
  The next scheduled meeting of each lead that has not ended by `now`:
  *Next*'s first rule and the lead page's banner. `%{lead_id => meeting}`.
  """
  @spec next_for_leads([binary()], DateTime.t()) :: %{binary() => Meeting.t()}
  def next_for_leads([], _now), do: %{}

  def next_for_leads(lead_ids, %DateTime{} = now) do
    from(m in Meeting,
      where: m.lead_id in ^lead_ids and m.status == :scheduled and m.ends_at > ^now,
      order_by: [asc: m.starts_at, asc: m.id]
    )
    |> Repo.all()
    |> Enum.group_by(& &1.lead_id)
    |> Map.new(fn {lead_id, [first | _rest]} -> {lead_id, first} end)
  end

  @doc "How many meetings a lead has."
  @spec count_for_lead(binary()) :: non_neg_integer()
  def count_for_lead(lead_id),
    do: Repo.aggregate(from(m in Meeting, where: m.lead_id == ^lead_id), :count)

  @doc """
  The customer's scheduled meetings on leads other than `lead_id`
  overlapping `[starts_at, ends_at)`, in any team (§8.1's clash), the
  meeting `except_id` left out, by start.
  """
  @spec overlapping(binary(), binary(), DateTime.t(), DateTime.t(), binary() | nil) :: [
          Meeting.t()
        ]
  def overlapping(customer_id, lead_id, starts_at, ends_at, except_id) do
    from(m in Meeting,
      join: l in Lead,
      on: l.id == m.lead_id,
      join: p in assoc(l, :profile),
      where:
        p.customer_id == ^customer_id and m.lead_id != ^lead_id and m.status == :scheduled and
          m.starts_at < ^ends_at and m.ends_at > ^starts_at,
      order_by: [asc: m.starts_at, asc: m.id]
    )
    |> then(&if(except_id, do: where(&1, [m], m.id != ^except_id), else: &1))
    |> load_all()
  end

  @doc "The scheduled meetings starting in `(now, until]`, across the organisations: the reminders' catch-up."
  @spec starting_for_system(DateTime.t(), DateTime.t()) :: [Meeting.t()]
  def starting_for_system(%DateTime{} = now, %DateTime{} = until) do
    from(m in Meeting,
      where: m.status == :scheduled and m.starts_at > ^now and m.starts_at <= ^until,
      order_by: [asc: m.starts_at]
    )
    |> load_all()
  end

  @doc "A meeting by id alone, whoever's: a reminder job's read."
  @spec get_for_system(term()) :: Meeting.t() | nil
  def get_for_system(id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> Meeting |> Repo.get(uuid) |> load()
      :error -> nil
    end
  end

  def get_for_system(_id), do: nil

  @spec create(map()) :: {:ok, Meeting.t()} | {:error, Ecto.Changeset.t()}
  def create(attrs) do
    with {:ok, m} <- %Meeting{} |> Meeting.changeset(attrs) |> Repo.insert(), do: {:ok, reload(m)}
  end

  @spec update(Meeting.t(), map()) :: {:ok, Meeting.t()} | {:error, Ecto.Changeset.t()}
  def update(%Meeting{} = m, attrs) do
    with {:ok, updated} <- m |> Meeting.changeset(attrs) |> Repo.update(),
         do: {:ok, reload(updated)}
  end

  @doc """
  The lead's meeting an invitation with this `UID` made (AQ-09 §9: the
  same UID again updates it), or `nil`.
  """
  @spec by_invite(binary(), String.t()) :: Meeting.t() | nil
  def by_invite(lead_id, uid) do
    from(m in Meeting,
      where: m.lead_id == ^lead_id and fragment("?->>'uid' = ?", m.proposal, ^uid),
      order_by: [desc: m.inserted_at],
      limit: 1
    )
    |> load_all()
    |> List.first()
  end

  @doc "A meeting deleted (a dismissed proposal); its attendees cascade."
  @spec delete(Meeting.t()) :: {:ok, Meeting.t()} | {:error, Ecto.Changeset.t()}
  def delete(%Meeting{} = m), do: Repo.delete(m)

  @doc "An attendee of a meeting."
  @spec add_attendee(map()) :: {:ok, Attendee.t()} | {:error, Ecto.Changeset.t()}
  def add_attendee(attrs), do: %Attendee{} |> Attendee.changeset(attrs) |> Repo.insert()

  defp load(nil), do: nil
  defp load(m), do: m |> Repo.preload(preload(), force: true) |> fill()

  defp load_all(query), do: query |> Repo.all() |> Repo.preload(preload()) |> Enum.map(&fill/1)

  defp fill(%Meeting{lead: lead} = m), do: %{m | lead: Data.Leads.fill(lead)}
end
