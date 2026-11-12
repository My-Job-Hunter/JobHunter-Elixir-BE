defmodule Core.Jobs.Act do
  @moduledoc """
  The verbs on a job (AQ-03 §7, §8), each one transaction with its audit
  row, each answering the sheet:

  | Verb | Who | Does |
  |---|---|---|
  | `close` `{from, reason}` | whoever may change it | open or unknown → closed, with `closed_at` and why |
  | `reopen` `{from}` | whoever may change it | closed → open |
  | `archive` · `unarchive` | a lead and above | hides the job from the list, or brings it back |
  | `merge` `{into_job_id}` | a lead and above | §8: this job into another of the same team; answers the survivor |
  | `dismiss` `{profile_id, reason, note?}` · `undismiss` | whoever may change it | *Not for this profile* |

  `from` is the status the person saw; a job whose status moved meanwhile
  answers `{:error, {:job_moved, job}}`, the 409 `job_moved` ("This job
  changed while you were looking. It's now closed."), P2's `task_moved`
  pattern.

  "Whoever may change it" is `Core.Access.Jobs`'s: the job's creator, its
  team's leads, the system admin, and a member of the team at
  `peer_jobs: edit` (AQ-03B §3.2).
  """

  alias Core.Access
  alias Core.Audit
  alias Core.Jobs
  alias Data.JobParts
  alias Data.Jobs, as: Store
  alias Data.Jobs.Job
  alias Data.Leads, as: LeadStore
  alias Data.Profiles
  alias Data.Repo
  alias Data.Scope
  alias Data.Vocabulary

  # Columns a merge fills together or not at all: half a salary from each
  # job is a salary nobody offered.
  @groups [
    ~w(comp_min_minor comp_max_minor comp_currency comp_period comp_source)a,
    ~w(equity_min_bp equity_max_bp)a,
    ~w(hours_min hours_max)a,
    ~w(overlap_from_time overlap_to_time)a
  ]

  # ── Close and reopen ────────────────────────────────────────────────────────

  @doc "`POST /jobs/:id/close {from, reason}`."
  @spec close(Scope.t(), term(), map(), DateTime.t()) :: {:ok, map()} | {:error, term()}
  def close(%Scope{} = scope, id, params, %DateTime{} = now) do
    params = Jobs.stringify(params)

    with {:ok, job} <- Jobs.fetch(scope, :close, id),
         :ok <- seen(job, params["from"]),
         :ok <-
           if(job.status == :closed, do: invalid("from", "the job is already closed"), else: :ok),
         {:ok, reason} <- reason(params["reason"], Vocabulary.job_close_reasons(), "reason") do
      attrs = %{
        status: :closed,
        closed_at: now,
        close_reason: reason,
        closed_by_user_id: Scope.user_id(scope),
        last_activity_at: now
      }

      Jobs.answer(scope, write(scope, "closed", job, &Store.close(&1, attrs), now), now)
    end
  end

  @doc "`POST /jobs/:id/reopen {from}`."
  @spec reopen(Scope.t(), term(), map(), DateTime.t()) :: {:ok, map()} | {:error, term()}
  def reopen(%Scope{} = scope, id, params, %DateTime{} = now) do
    params = Jobs.stringify(params)

    with {:ok, job} <- Jobs.fetch(scope, :reopen, id),
         :ok <- seen(job, params["from"]),
         :ok <- if(job.status == :closed, do: :ok, else: invalid("from", "the job is not closed")) do
      attrs = %{
        status: :open,
        closed_at: nil,
        close_reason: nil,
        closed_by_user_id: nil,
        last_activity_at: now
      }

      Jobs.answer(scope, write(scope, "reopened", job, &Store.close(&1, attrs), now), now)
    end
  end

  defp seen(_job, nil), do: {:error, {:missing, [:from]}}

  defp seen(job, from) do
    cond do
      to_string(from) not in Vocabulary.job_statuses() -> invalid("from", "is not a job status")
      to_string(from) != Atom.to_string(job.status) -> {:error, {:job_moved, job}}
      true -> :ok
    end
  end

  # ── Archive ─────────────────────────────────────────────────────────────────

  @doc "`POST /jobs/:id/archive`: a lead's; an archived job stays as it is."
  @spec archive(Scope.t(), term(), DateTime.t()) :: {:ok, map()} | {:error, term()}
  def archive(%Scope{} = scope, id, %DateTime{} = now) do
    with {:ok, job} <- Jobs.fetch(scope, :archive, id) do
      if job.archived_at,
        do: Jobs.answer(scope, {:ok, job}, now),
        else:
          Jobs.answer(
            scope,
            write(scope, "archived", job, &Store.archive(&1, now, Scope.user_id(scope)), now),
            now
          )
    end
  end

  @doc "`POST /jobs/:id/unarchive`: a lead's."
  @spec unarchive(Scope.t(), term(), DateTime.t()) :: {:ok, map()} | {:error, term()}
  def unarchive(%Scope{} = scope, id, %DateTime{} = now) do
    with {:ok, job} <- Jobs.fetch(scope, :unarchive, id) do
      if job.archived_at,
        do:
          Jobs.answer(
            scope,
            write(scope, "unarchived", job, &Store.archive(&1, nil, nil), now),
            now
          ),
        else: Jobs.answer(scope, {:ok, job}, now)
    end
  end

  @doc """
  P3's close of a job, inside the transaction of a lead's *Position closed*
  (AQ-04A §7: "Mark the job closed too", checked by default), with its own
  audit row. A job already closed is left as it is; a caller who may not
  close the job leaves it open (`:skipped`).
  """
  @spec close_for_lead(Scope.t(), Job.t(), DateTime.t()) :: :ok | :skipped | {:error, term()}
  def close_for_lead(%Scope{} = scope, %Job{} = job, %DateTime{} = now) do
    cond do
      job.status == :closed ->
        :ok

      not Access.can?(scope, :close, {:job, job}) ->
        :skipped

      true ->
        attrs = %{
          status: :closed,
          closed_at: now,
          close_reason: :other,
          closed_by_user_id: Scope.user_id(scope),
          last_activity_at: now
        }

        with {:ok, _job} <- write(scope, "closed", job, &Store.close(&1, attrs), now), do: :ok
    end
  end

  @doc """
  P3's unarchive of a job, inside the transaction of a lead's *Unarchive*
  (AQ-04A §5.3: unarchiving a lead unarchives its job), with its own audit row.
  """
  @spec unarchive_for_lead(Scope.t(), Job.t(), DateTime.t()) :: :ok | {:error, term()}
  def unarchive_for_lead(%Scope{} = scope, %Job{archived_at: %DateTime{}} = job, now) do
    with {:ok, _job} <- write(scope, "unarchived", job, &Store.archive(&1, nil, nil), now),
         do: :ok
  end

  def unarchive_for_lead(_scope, _job, _now), do: :ok

  # One verb, one transaction: the change and its audit row with the
  # status and archive columns before and after.
  defp write(scope, action, job, change, now) do
    Repo.transaction(fn ->
      case change.(job) do
        {:ok, updated} ->
          {:ok, _event} =
            Audit.record(scope, action, updated,
              before: verb_snapshot(job),
              after: verb_snapshot(updated),
              now: now
            )

          updated

        {:error, reason} ->
          Repo.rollback(reason)
      end
    end)
  end

  defp verb_snapshot(job), do: Audit.snapshot(job, ~w(status close_reason closed_at archived_at)a)

  # ── Merge (§8, QP3-8) ───────────────────────────────────────────────────────

  @doc """
  `POST /jobs/:id/merge {into_job_id}`: this job into the survivor, one
  transaction. The survivor keeps its values and fills each empty column
  (money, equity, hours and the overlap window as groups); skills are
  united; snapshots move, platform details where the survivor has none,
  dismissals unless the survivor has one for that profile; **leads move**
  (AQ-04A QP4a-17), and a profile with a lead on both jobs refuses the
  merge ("*Golang* has a lead on both jobs. Finish or archive one, then
  merge.", 422 on `into_job_id`); a `job_merges`
  row keeps this job's key, link and title, and every merge into this job
  is re-pointed; this job is deleted; the audit row names both. Answers
  the survivor's sheet.
  """
  @spec merge(Scope.t(), term(), map(), DateTime.t()) :: {:ok, map()} | {:error, term()}
  def merge(%Scope{} = scope, id, params, %DateTime{} = now) do
    params = Jobs.stringify(params)

    with {:ok, from} <- Jobs.fetch(scope, :merge, id),
         {:ok, into_id} <- required(params["into_job_id"], :into_job_id),
         :ok <- same_team(scope, from, into_id),
         {:ok, into} <- Jobs.fetch(scope, :read, into_id),
         :ok <- if(into.id == from.id, do: invalid("into_job_id", "is this job"), else: :ok),
         :ok <- no_lead_on_both(from, into) do
      Jobs.answer(scope, Repo.transaction(fn -> merge_into(scope, from, into, now) end), now)
    end
  end

  # AQ-03B §5.1: a job merges only into its own team's pool.
  defp same_team(scope, from, into_id) do
    case Store.get(Scope.organisation_id(scope), into_id) do
      %Job{team_id: team_id} when team_id != from.team_id ->
        invalid("into_job_id", "is in another team")

      _same_or_none ->
        :ok
    end
  end

  # QP4a-17: two leads for one profile would break `(job_id, profile_id)`;
  # which one survives is a person's call, made by finishing or archiving one.
  defp no_lead_on_both(from, into) do
    case LeadStore.profiles_on_both(from.id, into.id) do
      [] ->
        :ok

      ids ->
        titles =
          ids |> Enum.map(&Profiles.get/1) |> Enum.map_join(", ", &("*" <> &1.title <> "*"))

        verb = if length(ids) == 1, do: "has a lead", else: "have leads"

        invalid(
          "into_job_id",
          "#{titles} #{verb} on both jobs. Finish or archive one, then merge."
        )
    end
  end

  defp merge_into(scope, from, into, now) do
    fill = fill(from, into)

    with {:ok, survivor} <- Store.fill(into, fill),
         :ok <- JobParts.move_parts(from, survivor),
         moved = LeadStore.move_to_job(from.id, survivor.id),
         {:ok, _merge} <-
           JobParts.add_merge(%{
             organisation_id: from.organisation_id,
             team_id: survivor.team_id,
             into_job_id: survivor.id,
             from_canonical_key: from.canonical_key,
             from_source_url: from.source_url,
             from_title: from.title,
             merged_by_user_id: Scope.user_id(scope),
             merged_at: now
           }),
         {:ok, _gone} <- Store.delete(from),
         :ok <- Store.touch(survivor, now) do
      {:ok, _event} =
        Audit.record(scope, "merged", survivor,
          before: %{
            merged_job_id: from.id,
            merged_title: from.title,
            merged_canonical_key: from.canonical_key
          },
          after: %{
            into_job_id: survivor.id,
            moved_leads: moved,
            filled: fill |> Map.keys() |> Enum.map(&to_string/1) |> Enum.sort()
          },
          now: now
        )

      survivor
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  @doc false
  # The survivor's empty columns, from the merged job: `%{field => value}`.
  def fill(%Job{} = from, %Job{} = into) do
    grouped = List.flatten(@groups)

    singles =
      for field <- Job.editable_fields() -- grouped,
          blank?(Map.fetch!(into, field)),
          not blank?(Map.fetch!(from, field)),
          into: %{},
          do: {field, Map.fetch!(from, field)}

    Enum.reduce(@groups, singles, fn fields, acc ->
      if Enum.all?(fields, &blank?(Map.fetch!(into, &1))) and
           Enum.any?(fields, &(not blank?(Map.fetch!(from, &1)))),
         do: Map.merge(acc, Map.new(fields, &{&1, Map.fetch!(from, &1)})),
         else: acc
    end)
  end

  defp blank?(nil), do: true
  defp blank?([]), do: true
  defp blank?(""), do: true
  defp blank?(_value), do: false

  # ── Dismissals ──────────────────────────────────────────────────────────────

  @doc "`POST /jobs/:id/dismissals {profile_id, reason, note?}`: *Not for this profile*."
  @spec dismiss(Scope.t(), term(), map(), DateTime.t()) :: {:ok, map()} | {:error, term()}
  def dismiss(%Scope{} = scope, id, params, %DateTime{} = now) do
    params = Jobs.stringify(params)

    with {:ok, job} <- Jobs.fetch(scope, :dismiss, id),
         {:ok, profile} <- profile(scope, params["profile_id"]),
         {:ok, reason} <- reason(params["reason"], Vocabulary.job_dismiss_reasons(), "reason") do
      attrs = %{
        job_id: job.id,
        profile_id: profile.id,
        reason: reason,
        note: Utils.presence(params["note"]),
        dismissed_by_user_id: Scope.user_id(scope),
        dismissed_at: now
      }

      Jobs.answer(scope, Repo.transaction(fn -> put_dismissal(scope, job, attrs, now) end), now)
    end
  end

  defp put_dismissal(scope, job, attrs, now) do
    case JobParts.put_dismissal(attrs) do
      {:ok, _dismissal} ->
        after_ = %{profile_id: attrs.profile_id, reason: attrs.reason, note: attrs.note}
        {:ok, _event} = Audit.record(scope, "dismissed", job, after: after_, now: now)
        job

      {:error, changeset} ->
        Repo.rollback(changeset)
    end
  end

  @doc "`DELETE /jobs/:id/dismissals/:profile_id`: the suggestion is back."
  @spec undismiss(Scope.t(), term(), term(), DateTime.t()) :: {:ok, map()} | {:error, term()}
  def undismiss(%Scope{} = scope, id, profile_id, %DateTime{} = now) do
    with {:ok, job} <- Jobs.fetch(scope, :dismiss, id),
         {:ok, profile} <- profile(scope, profile_id),
         %{} = dismissal <- JobParts.get_dismissal(job.id, profile.id) || {:error, :not_found} do
      Repo.transaction(fn ->
        {:ok, _gone} = JobParts.delete_dismissal(dismissal)
        before = %{profile_id: profile.id, reason: dismissal.reason, note: dismissal.note}
        {:ok, _event} = Audit.record(scope, "undismissed", job, before: before, now: now)
        job
      end)
      |> then(&Jobs.answer(scope, &1, now))
    end
  end

  # A profile of the organisation the caller may read; anything else is not found.
  defp profile(_scope, nil), do: {:error, {:missing, [:profile_id]}}

  defp profile(scope, id) do
    with %{} = profile <- Profiles.get(id) || {:error, :not_found},
         true <-
           profile.customer.organisation_id == Scope.organisation_id(scope) ||
             {:error, :not_found},
         :ok <- Access.why_not(scope, :read, {:profile, profile}),
         do: {:ok, profile}
  end

  defp reason(nil, _allowed, field), do: {:error, {:missing, [String.to_existing_atom(field)]}}

  defp reason(value, allowed, field) do
    if to_string(value) in allowed,
      do: {:ok, String.to_existing_atom(to_string(value))},
      else: invalid(field, "is not one of the reasons")
  end

  defp required(value, _field) when is_binary(value) and value != "", do: {:ok, value}
  defp required(_value, field), do: {:error, {:missing, [field]}}

  defp invalid(field, message), do: {:error, {:invalid, %{field => [message]}}}
end
