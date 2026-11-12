defmodule Data.Approvals do
  @moduledoc """
  Approvals, their versions and files, reviewer slots, decisions, comments
  and the customers' policies (AQ-07 §5). Storage only: who sees or decides
  one is `Core.Access`'s (`Core.Access.Approvals`), the verbs
  `Core.Approvals.Act`'s, the defaults of a policy
  `Core.Approvals.Policies`'. Every read is the organisation's, or named
  `…_for_system` for a job.
  """

  import Ecto.Query, warn: false

  alias Data.Approvals.{Approval, Comment, Decision, Policy, Reviewer, Version, VersionMedia}
  alias Data.Repo

  @person [person: :photo]

  @doc "What every approval read carries: what it is about, its versions with files, slots and decisions."
  def preload do
    [
      :team,
      :conversation,
      customer: [:customer_teams],
      lead: Data.Leads.base_preload(),
      profile: [customer: [:customer_teams]],
      requested_by_user: @person,
      versions: [created_by_user: @person, proposed_document: [], media_links: [:media]],
      reviewers: [user: @person],
      decisions: [decided_by_user: @person]
    ]
  end

  # ── Approvals ───────────────────────────────────────────────────────────────

  @doc "An approval of the organisation; `nil` otherwise."
  @spec get(binary(), term()) :: Approval.t() | nil
  def get(organisation_id, id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} ->
        Approval |> Repo.get_by(id: uuid, organisation_id: organisation_id) |> load()

      :error ->
        nil
    end
  end

  def get(_organisation_id, _id), do: nil

  @doc "An approval by id alone, whoever's: a job's read."
  @spec get_for_system(term()) :: Approval.t() | nil
  def get_for_system(id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> Approval |> Repo.get(uuid) |> load()
      :error -> nil
    end
  end

  def get_for_system(_id), do: nil

  @doc "The approval again, fresh."
  @spec reload(Approval.t()) :: Approval.t()
  def reload(%Approval{} = a), do: get_for_system(a.id)

  @doc """
  Approvals by `opts`: `team_id`, `customer_id` (with `customer_slot:
  true`, only those with a customer slot, never a draft), `lead_id`,
  `profile_id`, `kind`, `state`, `ids`. Newest first, at most 500.
  """
  @spec list(keyword()) :: [Approval.t()]
  def list(opts) do
    from(a in Approval, order_by: [desc: a.updated_at, desc: a.id], limit: 500)
    |> narrow(opts)
    |> load_all()
  end

  defp narrow(query, opts) do
    Enum.reduce(opts, query, fn
      {:team_id, id}, q when is_binary(id) ->
        where(q, [a], a.team_id == ^id)

      {:customer_id, id}, q when is_binary(id) ->
        where(q, [a], a.customer_id == ^id)

      {:lead_id, id}, q when is_binary(id) ->
        where(q, [a], a.lead_id == ^id)

      {:profile_id, id}, q when is_binary(id) ->
        where(q, [a], a.profile_id == ^id)

      {:kind, kind}, q when is_atom(kind) and not is_nil(kind) ->
        where(q, [a], a.approval_kind == ^kind)

      {:state, state}, q when is_atom(state) and not is_nil(state) ->
        where(q, [a], a.state == ^state)

      {:ids, ids}, q when is_list(ids) ->
        where(q, [a], a.id in ^ids)

      {:customer_slot, true}, q ->
        where(q, [a], a.state != :draft and a.id in subquery(customer_slotted()))

      _other, q ->
        q
    end)
  end

  defp customer_slotted,
    do: from(r in Reviewer, where: r.slot == :customer, select: r.approval_id)

  @doc """
  The pending approvals a person may be waited on for: in `team_ids` (a
  team-lead slot), or naming `user_id` (a named slot, in any team).
  """
  @spec pending_for([binary()], binary() | nil) :: [Approval.t()]
  def pending_for(team_ids, user_id) do
    named =
      from(r in Reviewer, where: r.slot == :user and r.user_id == ^user_id, select: r.approval_id)

    from(a in Approval,
      where: a.state == :pending and (a.team_id in ^team_ids or a.id in subquery(named)),
      order_by: [desc: a.updated_at, desc: a.id]
    )
    |> load_all()
  end

  @doc "Moves an approval's `updated_at` (a decision that left it pending)."
  @spec touch(binary(), DateTime.t()) :: :ok
  def touch(id, %DateTime{} = at) do
    {_n, _rows} =
      from(a in Approval, where: a.id == ^id) |> Repo.update_all(set: [updated_at: at])

    :ok
  end

  @doc "The approval's row, locked for the rest of the transaction (a decision re-reads it)."
  @spec lock(binary()) :: Approval.t() | nil
  def lock(id), do: Repo.one(from(a in Approval, where: a.id == ^id, lock: "FOR UPDATE"))

  @doc "A lead's approvals, newest first."
  @spec for_lead(binary()) :: [Approval.t()]
  def for_lead(lead_id), do: list(lead_id: lead_id)

  @spec create(map()) :: {:ok, Approval.t()} | {:error, Ecto.Changeset.t()}
  def create(attrs), do: %Approval{} |> Approval.changeset(attrs) |> Repo.insert()

  @spec update(Approval.t(), map()) :: {:ok, Approval.t()} | {:error, Ecto.Changeset.t()}
  def update(%Approval{} = a, attrs), do: a |> Approval.changeset(attrs) |> Repo.update()

  # ── Versions and files ──────────────────────────────────────────────────────

  @spec add_version(map()) :: {:ok, Version.t()} | {:error, Ecto.Changeset.t()}
  def add_version(attrs), do: %Version{} |> Version.changeset(attrs) |> Repo.insert()

  @spec update_version(Version.t(), map()) :: {:ok, Version.t()} | {:error, Ecto.Changeset.t()}
  def update_version(%Version{} = v, attrs), do: v |> Version.changeset(attrs) |> Repo.update()

  @doc "A version's files become exactly `media_ids`, in that order."
  @spec put_media(binary(), [binary()]) :: :ok | {:error, Ecto.Changeset.t()}
  def put_media(version_id, media_ids) do
    Repo.delete_all(from(l in VersionMedia, where: l.approval_version_id == ^version_id))

    media_ids
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {media_id, i}, :ok ->
      %VersionMedia{}
      |> VersionMedia.changeset(%{
        approval_version_id: version_id,
        media_id: media_id,
        position: i
      })
      |> Repo.insert()
      |> case do
        {:ok, _link} -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  # ── Slots and decisions ─────────────────────────────────────────────────────

  @doc "The approval's slots become exactly `slots` (`[%{slot, user_id}]`), in order."
  @spec put_reviewers(binary(), [map()]) :: :ok | {:error, Ecto.Changeset.t()}
  def put_reviewers(approval_id, slots) do
    Repo.delete_all(from(r in Reviewer, where: r.approval_id == ^approval_id))

    slots
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {slot, i}, :ok ->
      %Reviewer{}
      |> Reviewer.changeset(Map.merge(slot, %{approval_id: approval_id, position: i}))
      |> Repo.insert()
      |> case do
        {:ok, _slot} -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  @spec add_decision(map()) :: {:ok, Decision.t()} | {:error, Ecto.Changeset.t()}
  def add_decision(attrs), do: %Decision{} |> Decision.changeset(attrs) |> Repo.insert()

  # ── Comments ────────────────────────────────────────────────────────────────

  @doc "An approval's comments, oldest first, with their authors."
  @spec comments(binary()) :: [Comment.t()]
  def comments(approval_id) do
    from(c in Comment,
      where: c.approval_id == ^approval_id,
      order_by: [asc: c.inserted_at, asc: c.id],
      preload: [author_user: ^@person]
    )
    |> Repo.all()
  end

  @doc "A comment by id, with its author; `nil` otherwise."
  @spec get_comment(term()) :: Comment.t() | nil
  def get_comment(id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} ->
        Comment |> Repo.get(uuid) |> then(&(&1 && Repo.preload(&1, author_user: @person)))

      :error ->
        nil
    end
  end

  def get_comment(_id), do: nil

  @spec add_comment(map()) :: {:ok, Comment.t()} | {:error, Ecto.Changeset.t()}
  def add_comment(attrs) do
    with {:ok, c} <- %Comment{} |> Comment.changeset(attrs) |> Repo.insert(),
         do: {:ok, Repo.preload(c, author_user: @person)}
  end

  @spec delete_comment(Comment.t(), DateTime.t()) ::
          {:ok, Comment.t()} | {:error, Ecto.Changeset.t()}
  def delete_comment(%Comment{} = c, %DateTime{} = at),
    do: c |> Comment.delete_changeset(at) |> Repo.update()

  @doc "How many live comments each approval has: `%{approval_id => n}`."
  @spec comment_counts([binary()]) :: %{binary() => non_neg_integer()}
  def comment_counts([]), do: %{}

  def comment_counts(ids) do
    from(c in Comment,
      where: c.approval_id in ^ids and is_nil(c.deleted_at),
      group_by: c.approval_id,
      select: {c.approval_id, count()}
    )
    |> Repo.all()
    |> Map.new()
  end

  # ── Policies ────────────────────────────────────────────────────────────────

  @doc "A customer's stored overrides, by kind."
  @spec policies(binary()) :: [Policy.t()]
  def policies(customer_id),
    do: Repo.all(from(p in Policy, where: p.customer_id == ^customer_id))

  @doc "A customer's override for `kind`, or `nil`."
  @spec get_policy(binary(), atom()) :: Policy.t() | nil
  def get_policy(customer_id, kind),
    do: Repo.get_by(Policy, customer_id: customer_id, approval_kind: kind)

  @doc "Writes the override for `(customer_id, approval_kind)`, replacing one there."
  @spec put_policy(map()) :: {:ok, Policy.t()} | {:error, Ecto.Changeset.t()}
  def put_policy(attrs) do
    (get_policy(attrs.customer_id, attrs.approval_kind) || %Policy{})
    |> Policy.changeset(attrs)
    |> Repo.insert_or_update()
  end

  @spec delete_policy(Policy.t()) :: {:ok, Policy.t()} | {:error, Ecto.Changeset.t()}
  def delete_policy(%Policy{} = p), do: Repo.delete(p)

  # ── Due, auto-approve, expiry, *Next* ───────────────────────────────────────

  @doc "Pending approvals with a due date before `until`, across the organisations: the reminders' catch-up."
  @spec due_before_for_system(DateTime.t()) :: [Approval.t()]
  def due_before_for_system(%DateTime{} = until) do
    from(a in Approval,
      where: a.state == :pending and not is_nil(a.due_at) and a.due_at <= ^until,
      order_by: [asc: a.due_at, asc: a.id]
    )
    |> load_all()
  end

  @doc "Pending approvals whose auto-approve time is at or before `now`, across the organisations."
  @spec auto_approvable_for_system(DateTime.t()) :: [Approval.t()]
  def auto_approvable_for_system(%DateTime{} = now) do
    from(a in Approval,
      where: a.state == :pending and not is_nil(a.auto_approve_at) and a.auto_approve_at <= ^now,
      order_by: [asc: a.auto_approve_at, asc: a.id]
    )
    |> load_all()
  end

  @doc "Pending approvals due at `cutoff` or before (the expiry's: three days past due), across the organisations."
  @spec expirable_for_system(DateTime.t()) :: [Approval.t()]
  def expirable_for_system(%DateTime{} = cutoff) do
    from(a in Approval,
      where: a.state == :pending and not is_nil(a.due_at) and a.due_at <= ^cutoff,
      order_by: [asc: a.due_at, asc: a.id]
    )
    |> load_all()
  end

  @doc """
  The pending approval due soonest on each lead (*Next*, AQ-07 QP7-18),
  bare (no preloads): `%{lead_id => approval}`.
  """
  @spec next_due_for_leads([binary()]) :: %{binary() => Approval.t()}
  def next_due_for_leads([]), do: %{}

  def next_due_for_leads(lead_ids) do
    from(a in Approval,
      where: a.lead_id in ^lead_ids and a.state == :pending and not is_nil(a.due_at),
      order_by: [asc: a.due_at, asc: a.id]
    )
    |> Repo.all()
    |> Enum.group_by(& &1.lead_id)
    |> Map.new(fn {lead_id, [first | _rest]} -> {lead_id, first} end)
  end

  # ── Retention ───────────────────────────────────────────────────────────────

  @doc """
  The files of a lead's approvals that nothing else holds — no other
  approval's version, task, message, document or photo — for a purge to
  delete with the rows (AQ-07 §10).
  """
  @spec media_held_only_by_lead(binary()) :: [Data.Files.Media.t()]
  def media_held_only_by_lead(lead_id) do
    mine =
      from(l in VersionMedia,
        join: v in Version,
        on: v.id == l.approval_version_id,
        join: a in Approval,
        on: a.id == v.approval_id,
        where: a.lead_id == ^lead_id,
        select: l.media_id
      )

    others =
      from(l in VersionMedia,
        join: v in Version,
        on: v.id == l.approval_version_id,
        join: a in Approval,
        on: a.id == v.approval_id,
        where: is_nil(a.lead_id) or a.lead_id != ^lead_id,
        select: l.media_id
      )

    from(m in Data.Files.Media,
      where: m.id in subquery(mine) and m.id not in subquery(others),
      where:
        fragment(
          "NOT EXISTS (SELECT 1 FROM task_media t WHERE t.media_id = ?) AND NOT EXISTS (SELECT 1 FROM message_media mm WHERE mm.media_id = ?) AND NOT EXISTS (SELECT 1 FROM document_media d WHERE d.media_id = ?) AND NOT EXISTS (SELECT 1 FROM person_photos p WHERE p.media_id = ?)",
          m.id,
          m.id,
          m.id,
          m.id
        )
    )
    |> Repo.all()
  end

  defp load(nil), do: nil
  defp load(a), do: a |> Repo.preload(preload(), force: true) |> fill()

  defp load_all(query), do: query |> Repo.all() |> Repo.preload(preload()) |> Enum.map(&fill/1)

  defp fill(%Approval{} = a) do
    %{
      a
      | lead: a.lead && Data.Leads.fill(a.lead),
        customer: Data.Customers.fill(a.customer),
        profile: a.profile && %{a.profile | customer: Data.Customers.fill(a.profile.customer)}
    }
  end
end
