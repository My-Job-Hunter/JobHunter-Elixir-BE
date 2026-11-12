defmodule Core.Leads do
  @moduledoc """
  Leads (AQ-04A P4a.1): a lead read, and made — saved or applied, on a job of
  the pool or on a new job in the same transaction (QP4a-18). The verbs are
  `Core.Leads.Act`, the guard `Core.Leads.Guard`, the board
  `Core.Leads.Board`, the shapes `Core.Leads.Sheet`, the ledger
  `Core.Leads.Ledger`, who is told `Core.Leads.Notices`, the pipelines
  `Core.Leads.Pipelines`, the portal's half `Core.Leads.Portal`.

  **A lead is in its job's team** (QP4a-8), made only for a customer that
  team serves ("Backend squad doesn't serve Imran."), never for a paused or
  ended customer or a paused profile (QP4a-10). Every function takes a
  `%Data.Scope{}` first and asks `Core.Access` (`{:lead, _}`, decided by
  `Core.Access.Leads`); a lead the caller may not see is `:not_found`.
  Every write is one transaction holding the change, its ledger row, its
  audit row and its notifications, and broadcasts after commit.
  """

  alias Core.Access
  alias Core.Audit
  alias Core.Jobs
  alias Core.Leads.{Guard, Ledger, Notices, Pipelines, Sheet}
  alias Core.Realtime
  alias Core.Tasks.Write
  alias Data.Customers.Profile
  alias Data.Documents
  alias Data.Leads, as: Store
  alias Data.Leads.Lead
  alias Data.Profiles
  alias Data.Scope
  alias Data.Teams
  alias Data.Vocabulary

  @audited ~w(state stage_id outcome owner_user_id pipeline_version_id applied_at is_pinned
              archived_at priority document_id)a
  @freelance [:freelance_hourly, :freelance_fixed]

  # ── Reads ───────────────────────────────────────────────────────────────────

  @doc "The lead behind `id`, if the caller may take `action` on it."
  @spec fetch(Scope.t(), atom(), term()) :: {:ok, Lead.t()} | {:error, term()}
  def fetch(%Scope{} = scope, action, id) do
    with %Lead{} = lead <- Store.get(Scope.organisation_id(scope), id) || {:error, :not_found},
         :ok <- Access.why_not(scope, action, {:lead, subject(lead)}),
         do: {:ok, lead}
  end

  @doc "`GET /leads/:id`: the sheet; the customer's view from the portal (§8.4)."
  @spec get(Scope.t(), term(), DateTime.t()) :: {:ok, map()} | {:error, term()}
  def get(%Scope{} = scope, id, %DateTime{} = now) do
    with {:ok, lead} <- fetch(scope, :read, id), do: {:ok, view(scope, lead, now)}
  end

  @doc "The sheet of a lead just written, as `scope` sees it."
  @spec answer(Scope.t(), {:ok, Lead.t()} | {:error, term()}, DateTime.t()) ::
          {:ok, map()} | {:error, term()}
  def answer(%Scope{} = scope, {:ok, %Lead{} = lead}, now),
    do: {:ok, view(scope, Store.reload(lead), now)}

  def answer(_scope, {:error, _reason} = error, _now), do: error

  defp view(scope, lead, now) do
    if Scope.customer?(scope),
      do: Sheet.customer_sheet(scope, lead, now),
      else: Sheet.sheet(scope, lead, now)
  end

  @doc "What `Core.Access.Leads` decides on, from a lead read with its job and profile."
  @spec subject(Lead.t()) :: map()
  def subject(%Lead{} = lead) do
    %{
      id: lead.id,
      organisation_id: lead.organisation_id,
      team_id: lead.job.team_id,
      owner_user_id: lead.owner_user_id,
      applied_by_user_id: lead.applied_by_user_id,
      customer_id: lead.profile.customer_id,
      state: lead.state,
      archived_at: lead.archived_at
    }
  end

  # ── Create (§7 save and apply, §8.1 `POST /leads`) ──────────────────────────

  @doc """
  `POST /leads {job_id | team_id + job: {…P3's job body…}, profile_id, as:
  save | apply, owner_user_id?, pipeline_key?, …the apply fields, again_reason?}`. With a
  `job` body the job is made in that team in the same transaction (P3's
  check re-run: 409 `job_exists`); then the guard, under its advisory lock
  (409 `duplicate_application`). `again_reason` (AQ-04B §7.2) is *Apply
  again…* on a pair whose lead was purged: the tombstone lets it through,
  the first `applied` carries `is_again` and the reason, and the team's
  leads are told. Answers the sheet.

  `opts` are what only the server sets (AQ-05 §10, the extension):
  `request_id` (the queued write's, on the first event), `confirmation`
  (`applied_confirmation`, `by_hand` otherwise) and `capture` (the new
  job's capture, `Core.Jobs.insert_new/5`); AQ-06 §7.3's `stage_kind`
  (`:inbound` for *Create job and lead* from triage) puts an applied lead
  at the version's first stage of that kind instead of its first `applied`.
  """
  @spec create(Scope.t(), map(), DateTime.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def create(%Scope{} = scope, params, %DateTime{} = now, opts \\ []) do
    params = stringify(params)

    with {:ok, as} <- as(params["as"]),
         {:ok, again} <- again(params, as),
         {:ok, profile} <- profile(scope, params["profile_id"]),
         {:ok, target} <- job_target(scope, params),
         :ok <- may_create(scope, target.team, profile),
         :ok <- live_profile(profile),
         {:ok, owner_id} <- owner(scope, target.team.id, params["owner_user_id"]),
         {:ok, facts} <-
           if(as == :apply, do: apply_fields(params, profile, now, opts), else: {:ok, %{}}) do
      fn -> insert(scope, {as, again, opts}, target, profile, owner_id, facts, params, now) end
      |> Write.commit()
      |> taken(scope, target, profile)
      |> then(&answer(scope, &1, now))
    end
  end

  defp insert(scope, {as, again, opts}, target, profile, owner_id, facts, params, now) do
    with {:ok, job} <- made_job(scope, target, now, opts),
         :ok <- Guard.lock!(scope, job.canonical_key, profile.id),
         :ok <- Guard.refuse(scope, job.canonical_key, job.team_id, profile, again: again),
         {:ok, version} <- version(scope, job, profile, params["pipeline_key"]),
         {:ok, lead} <-
           write_lead(scope, {as, opts[:stage_kind]}, job, profile, owner_id, version, facts, now) do
      event = first_event(scope, as, lead, again, now, opts[:request_id])

      {:ok, _audit} =
        Audit.record(scope, "created", lead, after: snapshot(lead), now: now)

      told = [
        if(lead.owner_user_id != Scope.user_id(scope),
          do: Notices.assigned(scope, lead, event),
          else: []
        ),
        if(as == :apply, do: Notices.customer_update(scope, lead, event, :applied), else: []),
        if(again, do: Notices.applied_again(scope, lead, event), else: [])
      ]

      {:ok, lead, [told, Realtime.lead_events("lead_created", lead)]}
    end
  end

  defp made_job(_scope, %{job: %{} = job}, _now, _opts), do: {:ok, job}

  defp made_job(scope, %{team: team, body: body}, now, opts) do
    case Jobs.insert_new(scope, team, body, now, Keyword.take(opts, [:capture])) do
      {:ok, job} -> {:ok, Data.Jobs.reload(job)}
      error -> error
    end
  end

  defp write_lead(scope, {as, stage_kind}, job, profile, owner_id, version, facts, now) do
    base = %{
      organisation_id: job.organisation_id,
      job_id: job.id,
      profile_id: profile.id,
      owner_user_id: owner_id,
      created_by_user_id: Scope.user_id(scope),
      pipeline_version_id: version.id,
      last_activity_at: now
    }

    attrs =
      if as == :apply,
        do:
          base
          |> Map.merge(facts)
          |> Map.merge(applied(scope, version, facts))
          |> Map.put(:state, :in_progress)
          |> at_kind(version, stage_kind),
        else: Map.put(base, :state, :todo)

    case Store.create(attrs) do
      {:ok, lead} -> {:ok, lead}
      {:error, changeset} -> unique_or(changeset)
    end
  end

  defp at_kind(attrs, _version, nil), do: attrs

  defp at_kind(attrs, version, kind) do
    case Enum.find(version.stages, &(&1.kind == kind)) do
      nil -> attrs
      stage -> Map.put(attrs, :stage_id, stage.id)
    end
  end

  # The unique `(job_id, profile_id)` is the backstop: the lead that landed
  # meanwhile is read once the transaction is gone, and answers the same 409.
  defp unique_or(%Ecto.Changeset{errors: errors} = changeset) do
    case errors[:profile_id] do
      {_message, opts} ->
        if opts[:constraint] == :unique, do: {:error, :lead_taken}, else: {:error, changeset}

      nil ->
        {:error, changeset}
    end
  end

  defp taken({:error, :lead_taken}, scope, %{job: job}, profile) do
    case Guard.refuse(scope, job.canonical_key, job.team_id, profile) do
      :ok -> {:error, :conflict}
      error -> error
    end
  end

  defp taken(result, _scope, _target, _profile), do: result

  @doc """
  The columns of an application: In progress at the version's first
  `applied` stage, by the caller, confirmed by hand — or as `facts` says
  (`applied_confirmation`, the extension's `page_confirmation`, AQ-05 §10.3).
  """
  @spec applied(Scope.t(), map(), map()) :: map()
  def applied(%Scope{} = scope, version, facts) do
    %{
      stage_id: first_applied(version).id,
      applied_at: facts[:applied_at],
      applied_by_user_id: Scope.user_id(scope),
      applied_confirmation: facts[:applied_confirmation] || :by_hand
    }
  end

  @doc "The version's first `applied` stage (every pipeline keeps one, §9.2)."
  def first_applied(version), do: Enum.find(version.stages, &(&1.kind == :applied))

  defp first_event(scope, :save, lead, _again, now, request_id),
    do: Ledger.record(scope, lead, :saved, %{to_label: "To do", request_id: request_id}, now)

  # After a purge (AQ-04B §7.2), *Apply again…* makes a new lead whose first
  # event says so: an `applied` with `is_again` and the reason.
  defp first_event(scope, :apply, lead, again, now, request_id),
    do:
      Ledger.record(
        scope,
        lead,
        :applied,
        %{to_label: lead.stage.name, occurred_at: lead.applied_at, request_id: request_id}
        |> Map.merge(if(again, do: %{is_again: true, note: again}, else: %{})),
        now
      )

  # ── The parts a create carries ──────────────────────────────────────────────

  # AQ-04B §7.2: `again_reason` applies again on a posting whose lead was
  # purged; a reason is required, and it is an application.
  defp again(%{"again_reason" => reason}, as) when not is_nil(reason) do
    cond do
      as != :apply -> invalid("as", "is apply when applying again")
      is_nil(blank(reason)) -> {:error, :override_reason_required}
      true -> {:ok, String.slice(blank(reason), 0, 1000)}
    end
  end

  defp again(_params, _as), do: {:ok, nil}

  defp as(as) when as in ["save", "apply"], do: {:ok, String.to_existing_atom(as)}
  defp as(nil), do: {:error, {:missing, [:as]}}
  defp as(_other), do: invalid("as", "is save or apply")

  @doc "A profile of the organisation the caller may read, with its customer; anything else is not found."
  @spec profile(Scope.t(), term()) :: {:ok, map()} | {:error, term()}
  def profile(_scope, nil), do: {:error, {:missing, [:profile_id]}}

  def profile(%Scope{} = scope, id) do
    with %{} = profile <- Profiles.get(id) || {:error, :not_found},
         true <-
           profile.customer.organisation_id == Scope.organisation_id(scope) ||
             {:error, :not_found},
         :ok <- Access.why_not(scope, :read, {:profile, profile}),
         do: {:ok, profile}
  end

  # `job_id`, or `team_id` with a new job's body.
  defp job_target(scope, %{"job_id" => id}) when is_binary(id) and id != "" do
    with {:ok, job} <- Jobs.fetch(scope, :read, id) do
      job = Data.Jobs.reload(job)
      {:ok, %{job: job, team: job.team}}
    end
  end

  defp job_target(scope, %{"job" => %{} = body} = params) do
    with {:ok, team} <- Jobs.team(scope, params),
         :ok <- Access.why_not(scope, :create, {:job, %{team_id: team.id}}),
         do: {:ok, %{team: team, body: body}}
  end

  defp job_target(_scope, _params), do: {:error, {:missing, [:job_id]}}

  defp may_create(scope, team, profile) do
    subject = %{team_id: team.id, team_name: team.name, customer: profile.customer}
    Access.why_not(scope, :create, {:lead, subject})
  end

  # QP4a-10: no new lead for a paused or ended customer, or a paused profile.
  defp live_profile(%{customer: %{status: status} = customer}) when status in [:paused, :ended],
    do: invalid("profile_id", "#{customer.display_name} is #{status_words(status)}")

  defp live_profile(%{status: :paused} = profile),
    do:
      invalid(
        "profile_id",
        "#{profile.title} is paused. Resume it before saving or applying for it."
      )

  defp live_profile(%{archived_at: %DateTime{}}), do: invalid("profile_id", "is archived")
  defp live_profile(_profile), do: :ok

  defp status_words(:paused), do: "paused. Resume them before saving or applying for them."
  defp status_words(:ended), do: "no longer a customer. Nothing new is saved or applied for them."

  @doc "The owner a write names: someone in the team, or the caller by default."
  @spec owner(Scope.t(), binary(), term()) :: {:ok, binary()} | {:error, term()}
  def owner(%Scope{} = scope, _team_id, nil), do: {:ok, Scope.user_id(scope)}
  def owner(%Scope{} = scope, team_id, ""), do: owner(scope, team_id, nil)

  def owner(%Scope{}, team_id, user_id) when is_binary(user_id) do
    case Ecto.UUID.cast(user_id) do
      {:ok, id} ->
        if Teams.get_open_member(team_id, id),
          do: {:ok, id},
          else: invalid("owner_user_id", "isn't in this lead's team")

      :error ->
        invalid("owner_user_id", "isn't in this lead's team")
    end
  end

  def owner(_scope, _team_id, _other), do: invalid("owner_user_id", "isn't in this lead's team")

  # §7: the job's engagement says *Freelance* for freelance work; else the
  # profile's default. The sheet may name one.
  defp version(scope, job, profile, key) do
    case key do
      nil ->
        key = if job.engagement in @freelance, do: :freelance, else: profile.default_pipeline_key
        {:ok, Pipelines.live(scope, key)}

      key ->
        case Enum.find(Pipelines.keys(), &(to_string(&1) == to_string(key))) do
          nil -> invalid("pipeline_key", "is employment or freelance")
          key -> {:ok, Pipelines.live(scope, key)}
        end
    end
  end

  @doc """
  The apply fields of §7 from `params`: `applied_at` (now by default, may be
  earlier, never later), `applied_via`, `document_id` (the profile's CV;
  its default when none is sent), `cover_letter_md`, the bid
  (`bid_minor`, `bid_currency`, `bid_period`), `connects_spent` and the
  expectation (`expectation_minor`, `expectation_currency`,
  `expectation_period`). Answers the columns; `opts[:confirmation]` (the
  extension's, AQ-05 §10.3) adds `applied_confirmation`.
  """
  @spec apply_fields(map(), map(), DateTime.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def apply_fields(params, profile, %DateTime{} = now, opts \\ []) do
    with {:ok, at} <- applied_at(params["applied_at"], now),
         {:ok, via} <- enum(params["applied_via"], Vocabulary.apply_methods(), "applied_via"),
         {:ok, document_id} <- document(params, profile) do
      {:ok,
       params
       |> Map.take(~w(cover_letter_md bid_minor bid_currency bid_period connects_spent
                      expectation_minor expectation_currency expectation_period))
       |> Map.new(fn {k, v} -> {String.to_existing_atom(k), blank(v)} end)
       |> Map.merge(%{applied_at: at, applied_via: via, document_id: document_id})
       |> then(
         &if(opts[:confirmation],
           do: Map.put(&1, :applied_confirmation, opts[:confirmation]),
           else: &1
         )
       )}
    end
  end

  @doc false
  # `applied_at` as sent: now by default, may be earlier, never later.
  def applied_at(nil, now), do: {:ok, now}
  def applied_at("", now), do: {:ok, now}

  def applied_at(value, now) do
    with {:ok, at} <- parse_at(value),
         :ok <- if(DateTime.after?(at, now), do: :later, else: :ok) do
      {:ok, at}
    else
      :later -> invalid("applied_at", "can't be in the future")
      _bad -> invalid("applied_at", "is not a time")
    end
  end

  defp parse_at(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, at, _offset} ->
        {:ok, at}

      _not_a_time ->
        with {:ok, day} <- Date.from_iso8601(value), do: DateTime.new(day, ~T[12:00:00])
    end
  end

  defp parse_at(_value), do: :error

  defp enum(nil, _allowed, _field), do: {:ok, nil}
  defp enum("", _allowed, _field), do: {:ok, nil}

  defp enum(value, allowed, field) do
    if to_string(value) in allowed,
      do: {:ok, String.to_existing_atom(to_string(value))},
      else: invalid(field, "is not one of the list")
  end

  @doc "A CV of the lead's profile (`document_id`), or the profile's default when none is sent."
  @spec document(map(), map()) :: {:ok, binary() | nil} | {:error, term()}
  def document(params, profile) do
    case Map.fetch(params, "document_id") do
      :error -> {:ok, Profile.default_document_id(profile)}
      {:ok, nil} -> {:ok, nil}
      {:ok, id} -> profile_document(id, profile)
    end
  end

  defp profile_document(id, profile) do
    case Documents.get(id) do
      %{profile_id: profile_id, archived_at: nil} = doc when profile_id == profile.id ->
        {:ok, doc.id}

      _other ->
        invalid("document_id", "is not a document of this profile")
    end
  end

  # ── Helpers shared with the verbs ───────────────────────────────────────────

  @doc false
  # The audited columns, with the lead's team and customer, so Customer ›
  # Activity finds a team's rows about its customer (AQ-04B QP4b-22).
  def snapshot(lead) do
    lead
    |> Audit.snapshot(@audited)
    |> Map.merge(%{"team_id" => team_id(lead), "customer_id" => customer_id(lead)})
  end

  defp team_id(%{job: %{team_id: id}}), do: id
  defp team_id(_lead), do: nil

  defp customer_id(%{profile: %{customer_id: id}}), do: id
  defp customer_id(_lead), do: nil

  @doc false
  def stringify(params) when is_map(params),
    do: Map.new(params, fn {k, v} -> {to_string(k), v} end)

  def stringify(_params), do: %{}

  @doc false
  def blank(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      _text -> value
    end
  end

  def blank(value), do: value

  @doc false
  def invalid(field, message), do: {:error, {:invalid, %{field => [message]}}}
end
