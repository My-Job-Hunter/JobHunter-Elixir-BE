defmodule Core.Ingest.Extension do
  @moduledoc """
  The side panel's job and leads (AQ-05 §10, §11): **lookup**, **capture**,
  ***Save for later***, ***I applied*** and ***Apply again…***, each built
  on the console's own functions — **one rule, one home**: P3's check
  (`Core.Jobs.Check`), P4a's guard (`Core.Leads.Guard`), P4a's `POST
  /leads` with a job body and `as` (`Core.Leads.create/4`) and its verbs
  (`Core.Leads.Act`). The adapter's raw strings are
  `Core.Ingest.Extension.Normalize`'s, the banner
  `Core.Ingest.Extension.Words`'s.

  **A job already in the team's pool** (§10.2, QP5-13), seen again by a
  capture, a save or an application: its blank fields are filled — a field
  with a value is never overwritten — its platform details refreshed, a
  snapshot of kind `fields` kept when the fields differ, a signals row when
  a fact differs (`Core.Jobs.Capture`), and `last_seen_at` and its activity
  move. At `peer_jobs: view` only *last seen* and the signals move. A job
  the caller may not see (a teammate's at `hidden`) is never touched.

  **Idempotency** (§10.4, QP5-17): every write carries the queued
  `request_id`, stored on the event it makes (`lead_events.request_id`); a
  retry of a write that landed answers the same lead with `answer:
  "replayed"`.

  **The identity** (§8, QP5-9): *I applied* from an account that is
  another customer's channel is `{:identity_mismatch, …}` (409); *Save*
  is allowed.

  Every write is `via: :extension` (the scope's), so its events are
  `actor_kind: extension` with the person, and they count as activity.
  """

  alias Core.Access
  alias Core.Extension.Context
  alias Core.Ingest.Extension.{Pool, Words}
  alias Core.Jobs
  alias Core.Jobs.Check
  alias Core.Jobs.Sheet, as: JobSheet
  alias Core.Leads
  alias Core.Leads.{Act, Guard}
  alias Core.Leads.Sheet, as: LeadSheet
  alias Core.Tasks
  alias Data.Leads, as: LeadStore
  alias Data.Scope

  @apply_facts ~w(applied_via applied_at document_id cover_letter_md bid_minor bid_currency
                  bid_period connects_spent)

  # ── Lookup ──────────────────────────────────────────────────────────────────

  @doc """
  `GET /ext/v1/jobs/lookup?url&team_id&profile_id?` (§10.5): P3's check and,
  with a profile, P4a's guard for it, plus the server's `banner` and what
  the panel may offer (`can: {save, apply, apply_again}`, `lead_id` of the
  profile's lead in this team when the caller sees it). A team the caller
  is not in is not found; the guard ignores visibility, as always.
  """
  @spec lookup(Scope.t(), map(), DateTime.t()) :: {:ok, map()} | {:error, term()}
  def lookup(%Scope{} = scope, params, %DateTime{} = now) do
    params = Leads.stringify(params)

    with :ok <- Access.why_not(scope, :use, :extension),
         {:ok, check} <- Check.run(scope, Map.take(params, ~w(team_id url profile_id)), now),
         {:ok, team} <- Jobs.team(scope, params),
         {:ok, profile} <- profile(scope, params["profile_id"]) do
      guard =
        if profile && check.state != "invalid",
          do: Guard.assess(scope, check.key, team.id, profile)

      ctx = %{scope: scope, profile: profile, team_id: team.id, zone: Tasks.zone(scope), now: now}

      {:ok,
       %{
         key: check[:key],
         source: check[:source],
         check: check,
         lead: check[:lead],
         banner: Words.banner(check, guard, ctx),
         can: can(scope, check, guard, team, profile),
         lead_id: guard && guard.existing && guard.existing[:lead_id]
       }}
    end
  end

  defp profile(_scope, id) when id in [nil, ""], do: {:ok, nil}
  defp profile(scope, id), do: Leads.profile(scope, id)

  @nothing %{save: false, apply: false, apply_again: false}

  # §10.5: what the panel offers, as the console would allow it.
  defp can(_scope, %{state: "invalid"}, _guard, _team, _profile), do: @nothing

  defp can(scope, check, guard, team, profile) do
    case guard && guard.answer do
      answer when answer in [nil, "free", "shared", "warn"] ->
        may? = new_lead?(check) and may_create?(scope, team, profile)
        %{save: may?, apply: may?, apply_again: false}

      "saved" ->
        %{@nothing | apply: may_on_lead?(scope, :apply, guard.lead)}

      "refused" ->
        %{@nothing | apply_again: may_on_lead?(scope, :apply_again, guard.lead)}

      _elsewhere ->
        @nothing
    end
  end

  defp new_lead?(check),
    do: check.state == "new" or (check.state == "in_pool" and not check.hidden)

  defp may_on_lead?(_scope, _verb, nil), do: false

  defp may_on_lead?(scope, verb, lead) do
    subject = Leads.subject(lead)
    Access.can?(scope, :read, {:lead, subject}) and Access.can?(scope, verb, {:lead, subject})
  end

  defp may_create?(_scope, _team, nil), do: true

  defp may_create?(scope, team, profile) do
    subject = %{team_id: team.id, team_name: team.name, customer: profile.customer}

    Access.can?(scope, :create, {:lead, subject}) and
      profile.customer.status not in [:paused, :ended] and profile.status != :paused and
      is_nil(profile.archived_at)
  end

  defp lead_visible?(scope, lead), do: Access.can?(scope, :read, {:lead, Leads.subject(lead)})

  # ── Capture ─────────────────────────────────────────────────────────────────

  @doc "`POST /ext/v1/jobs/capture {team_id, url, fields}` (§10.2): `Core.Ingest.Extension.Pool.capture/3`."
  @spec capture(Scope.t(), map(), DateTime.t()) :: {:ok, map()} | {:error, term()}
  defdelegate capture(scope, params, now), to: Pool

  # ── Save and applied ────────────────────────────────────────────────────────

  @doc """
  `POST /ext/v1/leads/save {request_id, team_id, profile_id, url, fields,
  identity?}`: a To do lead — P4a's save on the pool job (refreshed first,
  §10.2), or with a job body when the posting isn't in the pool, in one
  transaction. Answers `{:created, written}` or `{:replayed, written}`.
  """
  @spec save(Scope.t(), map(), DateTime.t()) :: {:ok, {atom(), map()}} | {:error, term()}
  def save(%Scope{} = scope, params, %DateTime{} = now) do
    params = Leads.stringify(params)

    with :ok <- Access.why_not(scope, :use, :extension),
         {:ok, request_id} <- request_id(params["request_id"]) do
      replayed(scope, request_id, now) || save_new(scope, request_id, params, now)
    end
  end

  defp save_new(scope, request_id, params, now) do
    with {:ok, fields} <- Pool.fields(params),
         {:ok, team} <- Jobs.team(scope, params),
         {:ok, profile} <- Leads.profile(scope, params["profile_id"]),
         {:ok, link} <- Pool.link(params["url"]) do
      norm = Pool.normalize(scope, fields, link.source, now)

      with {:ok, target} <- target(scope, team, link, params["url"], norm, now),
           body = Map.merge(target, %{"as" => "save", "profile_id" => profile.id}),
           {:ok, sheet} <-
             Leads.create(scope, body, now, request_id: request_id, capture: Pool.kept(norm)) do
        written(scope, :created, sheet.id, norm.unmatched_skills, now)
      end
    end
  end

  @doc """
  `POST /ext/v1/leads/applied {request_id, team_id, profile_id, url, fields,
  identity?, confirmation, applied_via, applied_at?, document_id?,
  cover_letter_md?, bid_minor?, bid_currency?, bid_period?, connects_spent?,
  from?}` (§10.3): with `from`, the profile's lead in this team is applied
  (P4a's `apply`: 409 `lead_moved` when it is not where the panel saw it);
  without, a new lead at *Applied* with the job (P4a's `POST /leads` with
  `as: apply`) — the guard's 409 when the profile has one. On a
  `page_confirmation` without `bid_minor`, the bid and the Connects are
  read from `fields.bid_text` and `fields.connects_spent_text`.
  `applied_via` defaults to the page's apply kind. Answers `{:created |
  :applied | :replayed, written}`.
  """
  @spec applied(Scope.t(), map(), DateTime.t()) :: {:ok, {atom(), map()}} | {:error, term()}
  def applied(%Scope{} = scope, params, %DateTime{} = now) do
    params = Leads.stringify(params)

    with :ok <- Access.why_not(scope, :use, :extension),
         {:ok, request_id} <- request_id(params["request_id"]) do
      replayed(scope, request_id, now) || applied_new(scope, request_id, params, now)
    end
  end

  defp applied_new(scope, request_id, params, now) do
    with {:ok, fields} <- Pool.fields(params),
         {:ok, confirmation} <- confirmation(params["confirmation"]),
         {:ok, team} <- Jobs.team(scope, params),
         {:ok, profile} <- Leads.profile(scope, params["profile_id"]),
         {:ok, link} <- Pool.link(params["url"]),
         :ok <- identity(scope, link.source, params["identity"], profile) do
      norm = Pool.normalize(scope, fields, link.source, now)
      facts = facts(params, norm, confirmation)
      opts = [request_id: request_id, confirmation: confirmation]
      guard = Guard.assess(scope, link.key, team.id, profile)

      if params["from"] && guard.answer in ~w(saved refused) && guard.lead &&
           lead_visible?(scope, guard.lead) do
        apply_lead(scope, guard.lead, Map.put(facts, "from", params["from"]), norm, opts, now)
      else
        create_applied(scope, {team, profile, link}, params["url"], facts, norm, opts, now)
      end
    end
  end

  defp apply_lead(scope, lead, facts, norm, opts, now) do
    with {:ok, _refreshed} <- refresh_visible(scope, lead.job, norm, now),
         {:ok, sheet} <- Act.run(scope, :apply, lead.id, facts, now, opts) do
      written(scope, :applied, sheet.id, norm.unmatched_skills, now)
    end
  end

  defp create_applied(scope, {team, profile, link}, url, facts, norm, opts, now) do
    with {:ok, target} <- target(scope, team, link, url, norm, now),
         body =
           target |> Map.merge(facts) |> Map.merge(%{"as" => "apply", "profile_id" => profile.id}),
         {:ok, sheet} <- Leads.create(scope, body, now, [{:capture, Pool.kept(norm)} | opts]) do
      written(scope, :created, sheet.id, norm.unmatched_skills, now)
    end
  end

  defp refresh_visible(scope, job, norm, now) do
    if Access.can?(scope, :read, {:job, job}),
      do: Pool.refresh(scope, job, norm, now),
      else: {:ok, nil}
  end

  # P4a's apply facts under P4a's names, as sent; a page confirmation's bid
  # and Connects from the page when the panel sent none; how, from the
  # page's apply kind when the panel did not say.
  defp facts(params, norm, confirmation) do
    page? = confirmation == :page_confirmation
    sent = Map.take(params, @apply_facts)
    bid = if norm.bid, do: Map.new(norm.bid, fn {k, v} -> {to_string(k), v} end), else: %{}

    sent
    |> merge_if(page? and is_nil(sent["bid_minor"]), bid)
    |> merge_if(page? and is_nil(sent["connects_spent"]), %{
      "connects_spent" => norm.connects_spent
    })
    |> merge_if(is_nil(sent["applied_via"]), %{"applied_via" => norm.job["apply_method"]})
    |> no_half_bid()
  end

  # The sheet sends the bid's currency and period by default; with no
  # amount there is no bid, not a field error.
  defp no_half_bid(%{"bid_minor" => minor} = facts) when not is_nil(minor), do: facts
  defp no_half_bid(facts), do: Map.drop(facts, ["bid_minor", "bid_currency", "bid_period"])

  # What the page read, where the panel sent nothing (and the page read something).
  defp merge_if(facts, true, read),
    do: Map.merge(facts, Map.reject(read, fn {_k, v} -> is_nil(v) end))

  defp merge_if(facts, false, _read), do: facts

  @doc """
  `POST /ext/v1/leads/:id/apply-again {request_id, from, reason, applied_via,
  applied_at?, document_id?, cover_letter_md?, bid_minor?, bid_currency?,
  bid_period?, connects_spent?}`: P4a's verb (422
  `override_reason_required` without a reason). Answers `{:applied |
  :replayed, written}`.
  """
  @spec apply_again(Scope.t(), term(), map(), DateTime.t()) ::
          {:ok, {atom(), map()}} | {:error, term()}
  def apply_again(%Scope{} = scope, id, params, %DateTime{} = now) do
    params = Leads.stringify(params)

    with :ok <- Access.why_not(scope, :use, :extension),
         {:ok, request_id} <- request_id(params["request_id"]) do
      replayed(scope, request_id, now) || again(scope, id, request_id, params, now)
    end
  end

  defp again(scope, id, request_id, params, now) do
    body = Map.take(params, ["from", "reason" | @apply_facts])

    with {:ok, sheet} <- Act.run(scope, :apply_again, id, body, now, request_id: request_id),
         do: written(scope, :applied, sheet.id, [], now)
  end

  # ── What every write shares ─────────────────────────────────────────────────

  # A retry of a write that landed: the lead its event made, as the caller
  # sees it now. `nil` when no event carries the id.
  defp replayed(scope, request_id, now) do
    case LeadStore.event_by_request(Scope.organisation_id(scope), request_id) do
      nil ->
        nil

      event ->
        with {:ok, lead} <- Leads.fetch(scope, :read, event.lead_id),
             do: written(scope, :replayed, lead.id, [], now)
    end
  end

  # Where the lead goes: the pool job (refreshed first, §10.2) by id; a key
  # not in the pool — or a teammate's job the caller may not see, which
  # P3's check answers with its 409 — as a new job's body.
  defp target(scope, team, link, url, norm, now) do
    case Pool.job(scope, team, link) do
      {:job, job} ->
        with {:ok, _refreshed} <- Pool.refresh(scope, job, norm, now),
             do: {:ok, %{"job_id" => job.id}}

      _none_or_hidden ->
        {:ok, %{"team_id" => team.id, "job" => body(url, norm)}}
    end
  end

  # P3's `POST /jobs` body from the page (`Core.Jobs.insert_new/5`).
  defp body(url, norm) do
    norm.job
    |> Map.put("url", url)
    |> then(&if(norm.company, do: Map.put(&1, "company", norm.company), else: &1))
    |> then(&if(norm.details == %{}, do: &1, else: Map.put(&1, "platform_details", norm.details)))
  end

  @doc false
  # §11.3's `written`: the answer, P4a's lead card, P3's job row, the skills
  # not in the vocabulary, and where the console opens it.
  def written(scope, answer, lead_id, unmatched, now) do
    lead = LeadStore.get(Scope.organisation_id(scope), lead_id)

    {:ok,
     {answer,
      %{
        answer: answer,
        lead: LeadSheet.card(lead, LeadSheet.today(scope, now)),
        job: JobSheet.row(lead.job, nil),
        unmatched_skills: unmatched,
        link_path: "/leads/#{lead.id}?team=#{lead.job.team_id}"
      }}}
  end

  # §8, QP5-9: an application from an account that is another customer's
  # channel is recorded on nobody's profile.
  defp identity(scope, source, link, profile) when source in [:linkedin, :upwork] do
    case Context.channel(scope, source, link) do
      {:channel, %{customer_id: id} = channel} when id != profile.customer_id ->
        {:error, {:identity_mismatch, mismatch(channel, profile, true)}}

      {:hidden, %{customer_id: id} = channel} when id != profile.customer_id ->
        {:error, {:identity_mismatch, mismatch(channel, profile, false)}}

      _same_or_none ->
        :ok
    end
  end

  defp identity(_scope, _source, _link, _profile), do: :ok

  defp mismatch(channel, profile, visible?) do
    %{
      channel:
        visible? &&
          %{
            id: channel.id,
            kind: channel.kind,
            customer: %{id: channel.customer.id, display_name: channel.customer.display_name}
          },
      kind: channel.kind,
      acting: %{display_name: profile.customer.display_name}
    }
  end

  defp request_id(id) do
    case is_binary(id) && Ecto.UUID.cast(id) do
      {:ok, uuid} -> {:ok, uuid}
      false -> {:error, {:missing, [:request_id]}}
      :error -> Leads.invalid("request_id", "is not a UUID")
    end
  end

  defp confirmation("by_hand"), do: {:ok, :by_hand}
  defp confirmation("page_confirmation"), do: {:ok, :page_confirmation}
  defp confirmation(nil), do: {:error, {:missing, [:confirmation]}}
  defp confirmation(_other), do: Leads.invalid("confirmation", "is by_hand or page_confirmation")
end
