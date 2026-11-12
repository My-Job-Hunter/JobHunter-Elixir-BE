defmodule Data.Fixtures.Leads do
  @moduledoc """
  The leads' fixtures (AQ-04A §12), reached through `Data.Fixtures`
  (`pipeline_fixture/2`, `lead_fixture/2`). Like the rest they take a scope
  and write through `Data.*`, so a lead that could not exist in production
  cannot be built: a lead's team is its job's, its version is a pipeline's
  of the scope's organisation, and each state carries the columns its CHECKs
  ask for.
  """

  alias Data.Leads
  alias Data.Pipelines
  alias Data.Scope

  @doc """
  A pipeline version of the scope's organisation: `key:` (`:employment` by
  default), `stages:` (`[%{key, name, kind, anchor_kind}]`; the defaults of
  AQ-04A §9.1 otherwise), numbered after the newest. Answers the version
  with its stages.
  """
  def pipeline_fixture(%Scope{} = scope, attrs \\ %{}) do
    attrs = Map.new(attrs)
    key = attrs[:key] || :employment
    org_id = Scope.organisation_id(scope)
    number = if live = Pipelines.live(org_id, key), do: live.number + 1, else: 1

    {:ok, version} =
      Pipelines.create_version(
        %{
          organisation_id: org_id,
          pipeline_key: key,
          number: number,
          inserted_at: DateTime.utc_now()
        },
        attrs[:stages] || Pipelines.defaults(key)
      )

    version
  end

  @doc """
  A lead made by `scope`'s person. Attrs: `job:` (a struct; else a new job in
  `team:` or the scope's first team), `profile:` (else a new customer served
  by the job's team, with one profile), `owner:` (a user; the scope's person
  by default), `pipeline:` (a version; the organisation's live one of the
  profile's default key, made when there is none), `as:` (`:save` or
  `:apply`), `state:` (`:todo`, `:in_progress`, `:on_hold`, `:done`; `:apply`
  means In progress), `stage:` (a stage key; the first `applied` one),
  `outcome:` (Done's; `:rejected` by default, `:not_pursued` from a lead
  never applied), `applied_at:`, `archived: true`, `is_pinned:`, and any
  other column — `last_activity_at:` and `archived_at:` for the retention
  policy's tests (AQ-04B §12).
  """
  def lead_fixture(%Scope{} = scope, attrs \\ %{}) do
    attrs = Map.new(attrs)
    now = DateTime.utc_now()
    job = attrs[:job] || Data.Fixtures.job_fixture(scope, Map.take(attrs, [:team]))
    job = Data.Jobs.reload(job)
    profile = attrs[:profile] || default_profile(job)
    version = attrs[:pipeline] || live(scope, profile.default_pipeline_key)
    state = state(attrs)
    applied? = applied?(state, attrs)

    base = %{
      organisation_id: job.organisation_id,
      job_id: job.id,
      profile_id: profile.id,
      owner_user_id: (attrs[:owner] && attrs[:owner].id) || Scope.user_id(scope),
      created_by_user_id: Scope.user_id(scope),
      pipeline_version_id: version.id,
      state: state,
      last_activity_at: now
    }

    applied = if applied?, do: applied_columns(scope, version, attrs, now), else: %{}

    {:ok, lead} =
      base
      |> Map.merge(applied)
      |> Map.merge(state_columns(state, applied?, attrs, now))
      |> Map.merge(archived_columns(attrs[:archived], now))
      |> Map.merge(
        Map.drop(attrs, [
          :job,
          :team,
          :profile,
          :owner,
          :pipeline,
          :as,
          :state,
          :stage,
          :outcome,
          :applied_at,
          :archived,
          :applied
        ])
      )
      |> Leads.create()

    lead
  end

  @doc """
  A note on `lead` by `scope`'s person (AQ-04B §12): `body_md:`, else a
  line of its own.
  """
  def note_fixture(%Scope{} = scope, lead, attrs \\ %{}) do
    attrs = Map.new(attrs)

    {:ok, note} =
      Data.LeadNotes.create(%{
        organisation_id: lead.organisation_id,
        lead_id: lead.id,
        author_user_id: Scope.user_id(scope),
        body_md: attrs[:body_md] || "A note #{System.unique_integer([:positive])}"
      })

    note
  end

  @doc "A label of `team` (AQ-04B §12): `name:`, else a unique one."
  def label_fixture(%Scope{} = scope, team, attrs \\ %{}) do
    attrs = Map.new(attrs)

    {:ok, label} =
      Data.Labels.create(%{
        organisation_id: Scope.organisation_id(scope) || team.organisation_id,
        team_id: team.id,
        name: attrs[:name] || "Label #{System.unique_integer([:positive])}"
      })

    label
  end

  @doc """
  A purged lead's tombstone (AQ-04B §12) for `profile` on `job`'s posting:
  `applied_on:` (a day; 16 Oct 2026 by default, `nil` for one never applied),
  `stage_kinds:`, `outcome:`, `purged_at:`, `team:`.
  """
  def fingerprint_fixture(%Scope{} = scope, job, profile, attrs \\ %{}) do
    attrs = Map.new(attrs)

    {:ok, fingerprint} =
      Data.Retention.add_fingerprint(%{
        organisation_id: Scope.organisation_id(scope) || job.organisation_id,
        team_id: (attrs[:team] && attrs[:team].id) || job.team_id,
        canonical_key: job.canonical_key,
        profile_id: profile.id,
        customer_id: profile.customer_id,
        applied_on: Map.get(attrs, :applied_on, ~D[2026-10-16]),
        stage_kinds: attrs[:stage_kinds] || [:applied],
        outcome: attrs[:outcome],
        purged_at: attrs[:purged_at] || DateTime.utc_now()
      })

    fingerprint
  end

  defp applied_columns(scope, version, attrs, now) do
    stage =
      Enum.find(version.stages, &(&1.key == to_string(attrs[:stage]))) ||
        Enum.find(version.stages, &(&1.kind == :applied))

    %{
      stage_id: stage.id,
      applied_at: attrs[:applied_at] || now,
      applied_by_user_id: Scope.user_id(scope),
      applied_confirmation: :by_hand
    }
  end

  defp archived_columns(true, now), do: %{archived_at: now, archive_reason: :by_hand}
  defp archived_columns(_live, _now), do: %{}

  defp applied?(:todo, _attrs), do: false
  defp applied?(:done, attrs), do: attrs[:outcome] != :not_pursued and attrs[:applied] != false
  defp applied?(_in_progress_or_on_hold, _attrs), do: true

  defp state(%{state: state}) when not is_nil(state), do: state
  defp state(%{as: :apply}), do: :in_progress
  defp state(_attrs), do: :todo

  defp state_columns(:on_hold, _applied?, _attrs, now),
    do: %{held_at: now, hold_reason: "Waiting to hear back"}

  defp state_columns(:done, applied?, attrs, now) do
    outcome = attrs[:outcome] || if(applied?, do: :rejected, else: :not_pursued)
    %{finished_at: now, outcome: outcome}
  end

  defp state_columns(_state, _applied?, _attrs, _now), do: %{}

  defp live(scope, key) do
    Pipelines.live(Scope.organisation_id(scope), key) || pipeline_fixture(scope, key: key)
  end

  defp default_profile(job) do
    org = Data.Organisations.get(job.organisation_id)
    customer = Data.Fixtures.customer_fixture(org, [%{id: job.team_id}])
    Data.Fixtures.profile_fixture(customer)
  end
end
