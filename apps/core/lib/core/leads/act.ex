defmodule Core.Leads.Act do
  @moduledoc """
  The verbs that move a lead (AQ-04A §7), the task's pattern (AQ-02 §7.2):
  **load → permission → at-state → move → event → audit → notify →
  broadcast**, one transaction. Every verb that moves carries what the
  client saw, `from: {state, stage}` (`stage` the stage key, or null); a
  lead that moved meanwhile answers `{:error, {:lead_moved, lead}}`, the
  409 `lead_moved` ("This lead moved while you were looking. It's now In
  progress · Technical interview 1.").

  | Verb (body besides `from`) | From | To |
  |---|---|---|
  | `apply` (the apply fields; `stage` from a drop) | To do | In progress · the version's first `applied` stage |
  | `apply_again` (the apply fields, `reason`) | In progress · On hold · Done (archived too) | In progress · Applied; 422 `override_reason_required` without a reason; an `applied` event with `is_again`; the hold or outcome cleared; unarchived; the team's leads told |
  | `move` (`state`, `stage`, `hold_reason?`, `hold_until_on?`, `outcome?`, `outcome_note?`, `close_job?`) | any but archived | a state, or In progress at any stage of its version: what a drop sends |
  | `hold` (`hold_reason`, `hold_until_on?`) | In progress | On hold; the stage is kept |
  | `resume` | On hold | In progress, at the stage it was held at |
  | `finish` (`outcome`, `outcome_note?`, `close_job?`) | In progress · On hold: any outcome but `not_pursued`; To do: `not_pursued` or `position_closed` | Done (422 `outcome_required`); *Hired* pins it; *Position closed* closes the job too unless `close_job: false` |
  | `reopen` | Done | In progress at the kept stage, or To do if it never left |

  The rest (archive, pin, assign, CV, pipeline, edit) are
  `Core.Leads.Change`'s; the portal's *I applied* is `portal_applied/4`.
  No verb ever moves another lead (PLAN §0).
  """

  import Core.Leads.Moves

  alias Core.Jobs.Act, as: JobAct
  alias Core.Leads
  alias Core.Leads.{Guard, Ledger, Notices, Words}
  alias Core.Tasks.Write
  alias Data.Repo
  alias Data.Scope
  alias Data.Vocabulary

  @verbs [:apply, :apply_again, :move, :hold, :resume, :finish, :reopen]
  @cleared_hold %{held_at: nil, hold_reason: nil, hold_until_on: nil}
  @cleared_outcome %{outcome: nil, outcome_note: nil, finished_at: nil}
  @unarchived %{archived_at: nil, archive_reason: nil, archived_by_user_id: nil}

  @doc """
  A verb on a lead (§7). Answers the sheet. `opts` are what only the
  server sets on an application (AQ-05 §10.3): `request_id` on its event,
  `confirmation` its `applied_confirmation`.
  """
  @spec run(Scope.t(), atom(), term(), map(), DateTime.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def run(%Scope{} = scope, verb, id, params, %DateTime{} = now, opts \\ [])
      when verb in @verbs do
    params = Leads.stringify(params)

    with {:ok, lead} <- Leads.fetch(scope, verb, id),
         :ok <- at(lead, params["from"]),
         :ok <- live(verb, lead) do
      Leads.answer(scope, verb(scope, verb, lead, params, now, opts), now)
    end
  end

  @doc """
  The portal's *I applied* (`POST /leads/:id/applied {from, applied_at?,
  applied_via?}`): To do → In progress · Applied, `actor_kind: customer`,
  confirmed by hand. Answers the customer's sheet.
  """
  @spec portal_applied(Scope.t(), term(), map(), DateTime.t()) :: {:ok, map()} | {:error, term()}
  def portal_applied(%Scope{} = scope, id, params, %DateTime{} = now) do
    params = params |> Leads.stringify() |> Map.take(~w(from applied_at applied_via))

    with {:ok, lead} <- Leads.fetch(scope, :applied, id),
         :ok <- at(lead, params["from"]) do
      Leads.answer(scope, apply_lead(scope, lead, params, now), now)
    end
  end

  @doc "`:ok` when the lead is still where the client saw it; the 409 otherwise."
  @spec at(map(), term()) :: :ok | {:error, term()}
  def at(_lead, nil), do: {:error, {:missing, [:from]}}

  def at(lead, %{} = from) do
    from = Leads.stringify(from)
    stage = lead.stage && lead.stage.key

    if to_string(from["state"]) == to_string(lead.state) and Leads.blank(from["stage"]) == stage,
      do: :ok,
      else: {:error, {:lead_moved, lead}}
  end

  def at(_lead, _from), do: Leads.invalid("from", "is {state, stage}")

  # An archived lead moves only by *Apply again* (which unarchives it).
  defp live(:apply_again, _lead), do: :ok
  defp live(_verb, %{archived_at: nil}), do: :ok

  defp live(_verb, _lead),
    do: Leads.invalid("state", "can't move an archived lead: unarchive it first")

  # ── Dispatch ────────────────────────────────────────────────────────────────

  defp verb(scope, :apply, lead, params, now, opts),
    do: apply_lead(scope, lead, params, now, opts)

  defp verb(scope, :apply_again, lead, params, now, opts),
    do: apply_again(scope, lead, params, now, opts)

  defp verb(scope, verb, lead, params, now, _opts), do: verb(scope, verb, lead, params, now)

  defp verb(scope, :hold, lead, params, now), do: hold(scope, lead, params, now)
  defp verb(scope, :resume, lead, params, now), do: resume(scope, lead, params, now)
  defp verb(scope, :finish, lead, params, now), do: finish(scope, lead, params, now)
  defp verb(scope, :reopen, lead, params, now), do: reopen(scope, lead, params, now)

  defp verb(scope, :move, lead, params, now) do
    with {:ok, to} <- target_state(params["state"]), do: move(scope, to, lead, params, now)
  end

  # What a drop sends, by the column it lands in.
  defp move(_scope, to, %{state: to} = lead, _params, _now) when to != :in_progress,
    do: {:ok, lead}

  defp move(scope, :todo, lead, params, now), do: to_todo(scope, lead, params, now)
  defp move(scope, :in_progress, lead, params, now), do: to_in_progress(scope, lead, params, now)
  defp move(scope, :on_hold, lead, params, now), do: hold(scope, lead, params, now)
  defp move(scope, :done, lead, params, now), do: finish(scope, lead, params, now)

  defp to_todo(scope, %{state: :done, stage_id: nil} = lead, params, now),
    do: reopen(scope, lead, params, now)

  defp to_todo(_scope, _lead, _params, _now),
    do: Leads.invalid("state", "can't go back to To do once applied")

  # A drop from To do (or a Done never applied) into In progress is an application.
  defp to_in_progress(scope, %{state: :in_progress} = lead, params, now),
    do: stage(scope, lead, params, now)

  defp to_in_progress(scope, %{state: :on_hold} = lead, params, now),
    do: resume(scope, lead, params, now)

  defp to_in_progress(scope, %{state: :done, stage_id: id} = lead, params, now)
       when is_binary(id),
       do: reopen(scope, lead, params, now)

  defp to_in_progress(scope, lead, params, now), do: apply_lead(scope, lead, params, now)

  defp target_state(nil), do: {:error, {:missing, [:state]}}

  defp target_state(state) do
    if to_string(state) in Vocabulary.lead_states(),
      do: {:ok, String.to_existing_atom(to_string(state))},
      else: Leads.invalid("state", "is not a state")
  end

  # ── Apply ───────────────────────────────────────────────────────────────────

  defp apply_lead(scope, lead, params, now, opts \\ [])

  defp apply_lead(scope, %{state: state, stage_id: stage_id} = lead, params, now, opts)
       when state == :todo or (state == :done and is_nil(stage_id)) do
    profile = Repo.preload(lead.profile, :default_document_link)
    version = lead.pipeline_version

    with {:ok, facts} <- Leads.apply_fields(params, profile, now, opts),
         {:ok, stage} <- stage_in(version, params["stage"], Leads.first_applied(version)) do
      attrs =
        facts
        |> Map.merge(Leads.applied(scope, version, facts))
        |> Map.merge(%{state: :in_progress, stage_id: stage.id})
        |> Map.merge(@cleared_outcome)

      Write.commit(fn -> applied(scope, lead, profile, attrs, {stage, opts}, now) end)
    end
  end

  defp apply_lead(_scope, lead, _params, _now, _opts), do: cant(:apply, lead)

  # Under the guard's lock: the profile has no other lead on the posting.
  defp applied(scope, lead, profile, attrs, {stage, opts}, now) do
    key = lead.job.canonical_key
    tell = &tell_applied(scope, lead, {stage, opts[:request_id]}, &1, now)

    with :ok <- Guard.lock!(scope, key, lead.profile_id),
         :ok <- Guard.refuse(scope, key, lead.job.team_id, profile, except: lead.id) do
      change(scope, lead, attrs, "applied", now, tell)
    end
  end

  defp tell_applied(scope, lead, {stage, request_id}, moved, now) do
    labels = %{
      from_label: Words.state(lead.state),
      to_label: stage.name,
      occurred_at: moved.applied_at,
      request_id: request_id
    }

    event = Ledger.record(scope, moved, :applied, labels, now)

    {[
       Notices.moved(scope, moved, event, stage.name),
       Notices.customer_update(scope, moved, event, :applied)
     ], "lead_moved"}
  end

  defp apply_again(scope, %{state: state} = lead, params, now, opts)
       when state in [:in_progress, :on_hold, :done] do
    profile = Repo.preload(lead.profile, :default_document_link)
    version = lead.pipeline_version

    with {:ok, reason} <- reason(params["reason"]),
         {:ok, facts} <- Leads.apply_fields(params, profile, now, opts) do
      sent = for {k, v} <- facts, Map.has_key?(params, to_string(k)), into: %{}, do: {k, v}

      attrs =
        sent
        |> Map.merge(Leads.applied(scope, version, facts))
        |> Map.merge(%{state: :in_progress})
        |> Map.merge(@unarchived)
        |> Map.merge(@cleared_hold)
        |> Map.merge(@cleared_outcome)

      Write.commit(fn ->
        change(
          scope,
          lead,
          attrs,
          "applied_again",
          now,
          &tell_again(scope, lead, {reason, opts[:request_id]}, &1, now)
        )
      end)
    end
  end

  defp apply_again(_scope, lead, _params, _now, _opts), do: cant(:apply_again, lead)

  defp reason(value) do
    case Leads.blank(value) do
      nil -> {:error, :override_reason_required}
      reason -> {:ok, String.slice(reason, 0, 1000)}
    end
  end

  defp tell_again(scope, lead, {reason, request_id}, moved, now) do
    stage = moved.stage

    labels = %{
      from_label: place(lead),
      to_label: stage.name,
      note: reason,
      is_again: true,
      occurred_at: moved.applied_at,
      request_id: request_id
    }

    event = Ledger.record(scope, moved, :applied, labels, now)

    {[
       Notices.applied_again(scope, moved, event),
       Notices.moved(scope, moved, event, stage.name),
       Notices.customer_update(scope, moved, event, :applied)
     ], "lead_moved"}
  end

  # ── Stage, hold, resume ─────────────────────────────────────────────────────

  # In progress at another stage of its version: any stage may follow any other.
  defp stage(scope, lead, params, now) do
    with {:ok, stage} <- stage_in(lead.pipeline_version, params["stage"], nil),
         do: restage(scope, lead, stage, now)
  end

  defp restage(_scope, %{stage_id: id} = lead, %{id: id}, _now), do: {:ok, lead}

  defp restage(scope, lead, stage, now) do
    tell = &tell_stage(scope, lead, stage, &1, now)
    Write.commit(fn -> change(scope, lead, %{stage_id: stage.id}, "moved", now, tell) end)
  end

  defp tell_stage(scope, lead, stage, moved, now) do
    event =
      Ledger.record(
        scope,
        moved,
        :stage_moved,
        %{from_label: lead.stage.name, to_label: stage.name},
        now
      )

    {[
       Notices.moved(scope, moved, event, stage.name),
       Notices.customer_update(scope, moved, event, {:stage, stage})
     ], "lead_moved"}
  end

  defp hold(scope, %{state: :in_progress} = lead, params, now) do
    with {:ok, reason} <- required_text(params["hold_reason"], :hold_reason),
         {:ok, until} <- day(params["hold_until_on"]) do
      reason = String.slice(reason, 0, 1000)
      attrs = %{state: :on_hold, held_at: now, hold_reason: reason, hold_until_on: until}

      Write.commit(fn ->
        change(scope, lead, attrs, "held", now, &tell_hold(scope, reason, &1, now))
      end)
    end
  end

  defp hold(_scope, lead, _params, _now), do: cant(:hold, lead)

  defp tell_hold(scope, reason, moved, now) do
    labels = %{from_label: "In progress", to_label: "On hold", note: reason}
    event = Ledger.record(scope, moved, :state_moved, labels, now)
    {[Notices.moved(scope, moved, event, "On hold")], "lead_moved"}
  end

  defp resume(scope, %{state: :on_hold} = lead, params, now) do
    with {:ok, stage} <- stage_in(lead.pipeline_version, params["stage"], lead.stage) do
      attrs = Map.merge(@cleared_hold, %{state: :in_progress, stage_id: stage.id})

      Write.commit(fn ->
        change(scope, lead, attrs, "resumed", now, &tell_resume(scope, lead, stage, &1, now))
      end)
    end
  end

  defp resume(_scope, lead, _params, _now), do: cant(:resume, lead)

  # A drop that also changes the stage writes the visit too.
  defp tell_resume(scope, lead, stage, moved, now) do
    labels = %{from_label: "On hold", to_label: "In progress"}
    event = Ledger.record(scope, moved, :state_moved, labels, now)
    told = Notices.moved(scope, moved, event, "In progress · " <> stage.name)

    if lead.stage_id == stage.id do
      {[told], "lead_moved"}
    else
      {staged, _event} = tell_stage(scope, lead, stage, moved, now)
      {[told, staged], "lead_moved"}
    end
  end

  # ── Finish, reopen ──────────────────────────────────────────────────────────

  defp finish(scope, %{state: state} = lead, params, now)
       when state in [:todo, :in_progress, :on_hold] do
    with {:ok, outcome} <- outcome(params["outcome"]),
         :ok <- outcome_allowed(state, outcome) do
      attrs =
        @cleared_hold
        |> Map.merge(%{
          state: :done,
          outcome: outcome,
          outcome_note: Leads.blank(params["outcome_note"]),
          finished_at: now
        })
        |> Map.merge(if(outcome == :hired, do: %{is_pinned: true}, else: %{}))

      close? = outcome == :position_closed and params["close_job"] not in [false, "false"]
      Write.commit(fn -> finished(scope, lead, attrs, close?, now) end)
    end
  end

  defp finish(_scope, lead, _params, _now), do: cant(:finish, lead)

  defp finished(scope, lead, attrs, close?, now) do
    with :ok <- close_job(scope, lead, close?, now) do
      change(scope, lead, attrs, "finished", now, &tell_finish(scope, lead, attrs, &1, now))
    end
  end

  defp tell_finish(scope, lead, attrs, moved, now) do
    outcome = attrs.outcome

    labels = %{
      from_label: place(lead),
      to_label: Words.outcome(outcome),
      outcome: outcome,
      note: attrs.outcome_note
    }

    event = Ledger.record(scope, moved, :outcome_set, labels, now)

    {[
       Notices.moved(scope, moved, event, Words.outcome(outcome)),
       Notices.customer_update(scope, moved, event, {:outcome, outcome})
     ], "lead_moved"}
  end

  defp close_job(_scope, _lead, false, _now), do: :ok

  defp close_job(scope, lead, true, now) do
    case JobAct.close_for_lead(scope, lead.job, now) do
      {:error, _reason} = error -> error
      _closed_or_skipped -> :ok
    end
  end

  defp outcome(nil), do: {:error, :outcome_required}
  defp outcome(""), do: {:error, :outcome_required}

  defp outcome(value) do
    if to_string(value) in Vocabulary.lead_outcomes(),
      do: {:ok, String.to_existing_atom(to_string(value))},
      else: Leads.invalid("outcome", "is not an outcome")
  end

  # QP4a-11: nobody is rejected for a job never applied to.
  defp outcome_allowed(:todo, outcome) when outcome in [:not_pursued, :position_closed], do: :ok

  defp outcome_allowed(:todo, _outcome),
    do: Leads.invalid("outcome", "from To do is Not pursued or Position closed")

  defp outcome_allowed(_state, :not_pursued),
    do: Leads.invalid("outcome", "Not pursued is for a lead never applied to")

  defp outcome_allowed(_state, _outcome), do: :ok

  # QP4a-12: back where it finished. A Hired lead keeps its pin.
  defp reopen(scope, %{state: :done} = lead, params, now) do
    with {:ok, to} <- reopened(lead, params) do
      attrs = Map.merge(@cleared_outcome, to)

      Write.commit(fn ->
        change(scope, lead, attrs, "reopened", now, &tell_reopen(scope, lead, &1, now))
      end)
    end
  end

  defp reopen(_scope, lead, _params, _now), do: cant(:reopen, lead)

  defp reopened(%{stage_id: nil}, _params), do: {:ok, %{state: :todo}}

  defp reopened(lead, params) do
    with {:ok, stage} <- stage_in(lead.pipeline_version, params["stage"], lead.stage),
         do: {:ok, %{state: :in_progress, stage_id: stage.id}}
  end

  defp tell_reopen(scope, lead, moved, now) do
    labels = %{from_label: Words.outcome(lead.outcome), to_label: place(moved)}
    event = Ledger.record(scope, moved, :reopened, labels, now)

    {[
       Notices.moved(scope, moved, event, place(moved)),
       Notices.customer_update(scope, moved, event, :reopened)
     ], "lead_moved"}
  end
end
