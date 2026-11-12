defmodule Core.Leads.Change do
  @moduledoc """
  The verbs that keep, hand on or edit a lead without moving it (AQ-04A §7),
  each one transaction answering the sheet:

  | Verb | Does | Ledger |
  |---|---|---|
  | `archive` · `unarchive` | the flag (by hand, `by_hand`), the state kept; unarchiving also unarchives the job if it is archived (§5.3) | `archived` · `unarchived` |
  | `pin` · `unpin` | the flag; exempt from P4b's sweep | none: audited only |
  | `assign {owner_user_id}` | a new owner, someone in the lead's team; the new owner is told | `owner_changed`, both names frozen |
  | `cv {document_id}` | a document of the lead's profile | `cv_set` |
  | `pipeline {from, pipeline_key?}` | To do · In progress · On hold onto the other pipeline's live version (or this one's newest); the stage maps by kind, else to the first `applied` stage | `pipeline_changed` |
  | `edit` (`PATCH /leads/:id`) | `priority`, `applied_at`, `applied_via`, `cover_letter_md`, the bid, `connects_spent`, the expectation | none: facts, not moves |

  Archive and pin are the owner's or a team lead's; assign the owner's or a
  lead's; the rest whoever may change the lead (`Core.Access.Leads`).
  """

  alias Core.Audit
  alias Core.Jobs.Act, as: JobAct
  alias Core.Leads
  alias Core.Leads.{Act, Ledger, Moves, Notices, Pipelines}
  alias Core.Tasks.Write
  alias Data.Accounts
  alias Data.Leads, as: Store
  alias Data.Scope
  alias Data.Vocabulary

  @editable ~w(priority applied_at applied_via cover_letter_md bid_minor bid_currency bid_period
               connects_spent expectation_minor expectation_currency expectation_period)

  # ── Archive, pin ────────────────────────────────────────────────────────────

  @doc "`POST /leads/:id/{archive,unarchive,pin,unpin}`."
  @spec flag(Scope.t(), atom(), term(), DateTime.t()) :: {:ok, map()} | {:error, term()}
  def flag(%Scope{} = scope, verb, id, %DateTime{} = now)
      when verb in [:archive, :unarchive, :pin, :unpin] do
    with {:ok, lead} <- Leads.fetch(scope, verb, id) do
      Leads.answer(scope, flag_write(scope, verb, lead, now), now)
    end
  end

  defp flag_write(_scope, :archive, %{archived_at: %DateTime{}} = lead, _now), do: {:ok, lead}
  defp flag_write(_scope, :unarchive, %{archived_at: nil} = lead, _now), do: {:ok, lead}
  defp flag_write(_scope, :pin, %{is_pinned: true} = lead, _now), do: {:ok, lead}
  defp flag_write(_scope, :unpin, %{is_pinned: false} = lead, _now), do: {:ok, lead}

  defp flag_write(scope, :archive, lead, now) do
    attrs = %{
      archived_at: now,
      archive_reason: :by_hand,
      archived_by_user_id: Scope.user_id(scope)
    }

    Write.commit(fn ->
      Moves.change(scope, lead, attrs, "archived", now, fn moved ->
        _event = Ledger.record(scope, moved, :archived, %{to_label: "Archived"}, now)
        {[], "lead_moved"}
      end)
    end)
  end

  defp flag_write(scope, :unarchive, lead, now) do
    attrs = %{archived_at: nil, archive_reason: nil, archived_by_user_id: nil}

    Write.commit(fn -> unarchived(scope, lead, attrs, now) end)
  end

  defp flag_write(scope, verb, lead, now) do
    pinned? = verb == :pin

    Write.commit(fn ->
      Moves.change(
        scope,
        lead,
        %{is_pinned: pinned?},
        if(pinned?, do: "pinned", else: "unpinned"),
        now,
        fn _moved ->
          {[], "lead_updated"}
        end
      )
    end)
  end

  defp unarchived(scope, lead, attrs, now) do
    with :ok <- JobAct.unarchive_for_lead(scope, lead.job, now) do
      Moves.change(scope, lead, attrs, "unarchived", now, fn moved ->
        _event = Ledger.record(scope, moved, :unarchived, %{from_label: "Archived"}, now)
        {[], "lead_moved"}
      end)
    end
  end

  # ── Assign, CV ──────────────────────────────────────────────────────────────

  @doc "`POST /leads/:id/assign {owner_user_id}`."
  @spec assign(Scope.t(), term(), map(), DateTime.t()) :: {:ok, map()} | {:error, term()}
  def assign(%Scope{} = scope, id, params, %DateTime{} = now) do
    params = Leads.stringify(params)

    with {:ok, lead} <- Leads.fetch(scope, :assign, id),
         :ok <-
           if(is_nil(params["owner_user_id"]),
             do: {:error, {:missing, [:owner_user_id]}},
             else: :ok
           ),
         {:ok, owner_id} <- Leads.owner(scope, lead.job.team_id, params["owner_user_id"]) do
      if owner_id == lead.owner_user_id,
        do: Leads.answer(scope, {:ok, lead}, now),
        else: Leads.answer(scope, hand_on(scope, lead, owner_id, now), now)
    end
  end

  defp hand_on(scope, lead, owner_id, now) do
    to = owner_id |> Accounts.get_user() |> Accounts.with_person()

    Write.commit(fn ->
      Moves.change(scope, lead, %{owner_user_id: owner_id}, "assigned", now, fn moved ->
        event =
          Ledger.record(
            scope,
            moved,
            :owner_changed,
            %{from_label: lead.owner_user.person.display_name, to_label: to.person.display_name},
            now
          )

        {[Notices.assigned(scope, moved, event)], "lead_updated"}
      end)
    end)
  end

  @doc "`POST /leads/:id/cv {document_id}`: a document of the lead's profile."
  @spec cv(Scope.t(), term(), map(), DateTime.t()) :: {:ok, map()} | {:error, term()}
  def cv(%Scope{} = scope, id, params, %DateTime{} = now) do
    params = Leads.stringify(params)

    with {:ok, lead} <- Leads.fetch(scope, :cv, id),
         :ok <-
           if(Map.has_key?(params, "document_id"),
             do: :ok,
             else: {:error, {:missing, [:document_id]}}
           ),
         {:ok, document_id} <- Leads.document(params, lead.profile) do
      if document_id == lead.document_id,
        do: Leads.answer(scope, {:ok, lead}, now),
        else: Leads.answer(scope, set_cv(scope, lead, document_id, now), now)
    end
  end

  @doc """
  The CV write itself, one transaction with its `cv_set` row and audit, for
  a caller that has decided it may: `cv/4` above, and an approved
  `cv_for_job` on its requester's behalf (AQ-07 §7) — `ledger` adds to the
  row (the approval's words in `note`).
  """
  @spec set_cv(Scope.t(), map(), binary() | nil, DateTime.t(), map()) ::
          {:ok, map()} | {:error, term()}
  def set_cv(%Scope{} = scope, lead, document_id, %DateTime{} = now, ledger \\ %{}) do
    before = lead |> Store.sheet() |> Map.get(:document)
    after_ = document_id && Data.Documents.get(document_id)

    Write.commit(fn ->
      Moves.change(scope, lead, %{document_id: document_id}, "cv_set", now, fn moved ->
        _event =
          Ledger.record(
            scope,
            moved,
            :cv_set,
            Map.merge(ledger, %{
              from_label: before && before.label,
              to_label: after_ && after_.label,
              document_id: document_id
            }),
            now
          )

        {[], "lead_updated"}
      end)
    end)
  end

  # ── Pipeline ────────────────────────────────────────────────────────────────

  @doc """
  `POST /leads/:id/pipeline {from, pipeline_key?}`: onto the live version of
  `pipeline_key` (the other pipeline by default).
  """
  @spec pipeline(Scope.t(), term(), map(), DateTime.t()) :: {:ok, map()} | {:error, term()}
  def pipeline(%Scope{} = scope, id, params, %DateTime{} = now) do
    params = Leads.stringify(params)

    with {:ok, lead} <- Leads.fetch(scope, :pipeline, id),
         :ok <- Act.at(lead, params["from"]),
         :ok <- movable(lead),
         {:ok, key} <- pipeline_key(lead, params["pipeline_key"]) do
      version = Pipelines.live(scope, key)

      if version.id == lead.pipeline_version_id,
        do: Leads.invalid("pipeline_key", "is already this lead's, at its newest version"),
        else: Leads.answer(scope, switch(scope, lead, version, now), now)
    end
  end

  defp movable(%{archived_at: %DateTime{}}),
    do: Leads.invalid("state", "can't change an archived lead")

  defp movable(%{state: state}) when state in [:todo, :in_progress, :on_hold], do: :ok

  defp movable(_lead),
    do: Leads.invalid("state", "can't change the pipeline of a lead that is Done")

  defp pipeline_key(lead, nil) do
    current = lead.pipeline_version.pipeline_key
    {:ok, Enum.find(Pipelines.keys(), &(&1 != current))}
  end

  defp pipeline_key(_lead, key) do
    case Enum.find(Pipelines.keys(), &(to_string(&1) == to_string(key))) do
      nil -> Leads.invalid("pipeline_key", "is employment or freelance")
      key -> {:ok, key}
    end
  end

  defp switch(scope, lead, version, now) do
    stage = lead.stage && mapped(lead.stage, version)
    from = Pipelines.name(lead.pipeline_version.pipeline_key)

    Write.commit(fn ->
      attrs = %{pipeline_version_id: version.id, stage_id: stage && stage.id}

      Moves.change(scope, lead, attrs, "pipeline_changed", now, fn moved ->
        _event =
          Ledger.record(
            scope,
            moved,
            :pipeline_changed,
            %{from_label: from, to_label: Pipelines.name(version.pipeline_key)},
            now
          )

        {[], "lead_updated"}
      end)
    end)
  end

  # The first stage of the same kind (a custom stage by its anchor's), else
  # the first `applied` stage.
  defp mapped(stage, version) do
    kind = if stage.kind == :custom, do: stage.anchor_kind, else: stage.kind
    Enum.find(version.stages, &(&1.kind == kind)) || Leads.first_applied(version)
  end

  # ── Edit ────────────────────────────────────────────────────────────────────

  @doc "`PATCH /leads/:id`: the facts of §7's *edit*. Audited with what changed; no event."
  @spec edit(Scope.t(), term(), map(), DateTime.t()) :: {:ok, map()} | {:error, term()}
  def edit(%Scope{} = scope, id, params, %DateTime{} = now) do
    with {:ok, lead} <- Leads.fetch(scope, :edit, id),
         do: Leads.answer(scope, save_facts(scope, lead, params, now), now)
  end

  @doc """
  The facts write itself, one transaction with its audit row, for a caller
  that has decided it may: `edit/4` above, and an approved `proposal`,
  `rate` or `cover_letter` on its requester's behalf (AQ-07 §7). Answers
  the lead.
  """
  @spec save_facts(Scope.t(), map(), map(), DateTime.t()) :: {:ok, map()} | {:error, term()}
  def save_facts(%Scope{} = scope, lead, params, %DateTime{} = now) do
    params = params |> Leads.stringify() |> Map.take(@editable)

    with {:ok, attrs} <- facts(lead, params, now),
         do: Write.commit(fn -> save(scope, lead, attrs, now) end)
  end

  defp facts(lead, params, now) do
    with {:ok, priority} <- enum(params, "priority", Vocabulary.lead_priorities()),
         {:ok, via} <- enum(params, "applied_via", Vocabulary.apply_methods()),
         {:ok, at} <- applied_at(lead, params, now) do
      attrs =
        params
        |> Map.drop(~w(priority applied_via applied_at))
        |> Map.new(fn {k, v} -> {String.to_existing_atom(k), Leads.blank(v)} end)
        |> Map.merge(priority)
        |> Map.merge(via)
        |> Map.merge(at)

      {:ok, attrs}
    end
  end

  defp enum(params, field, allowed) do
    case Map.fetch(params, field) do
      :error ->
        {:ok, %{}}

      {:ok, v} when v in [nil, ""] ->
        {:ok, %{String.to_existing_atom(field) => nil}}

      {:ok, v} ->
        if(to_string(v) in allowed,
          do: {:ok, %{String.to_existing_atom(field) => String.to_existing_atom(to_string(v))}},
          else: Leads.invalid(field, "is not one of the list")
        )
    end
  end

  defp applied_at(lead, params, now) do
    case Map.fetch(params, "applied_at") do
      :error ->
        {:ok, %{}}

      {:ok, _value} when is_nil(lead.applied_at) ->
        Leads.invalid("applied_at", "is set by applying")

      {:ok, value} ->
        with {:ok, at} <- Leads.applied_at(value, now), do: {:ok, %{applied_at: at}}
    end
  end

  defp save(scope, lead, attrs, now) do
    with {:ok, updated} <- Store.update(lead, attrs) do
      keys = Map.keys(attrs)
      before = Audit.snapshot(lead, keys)
      after_ = Audit.snapshot(updated, keys)

      if before != after_ do
        {:ok, _audit} =
          Audit.record(scope, "updated", updated, before: before, after: after_, now: now)
      end

      {:ok, updated, [Core.Realtime.lead_events("lead_updated", updated)]}
    end
  end
end
