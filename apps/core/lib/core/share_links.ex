defmodule Core.ShareLinks do
  @moduledoc """
  Share links (AQ-03B §3.3, §5.1; AQ-04A QP4a-20): one task, job or lead
  shown **read-only**,
  at a level, to any signed-in staff member of the organisation who holds
  the link.

  | Verb | Who |
  |---|---|
  | `create/4` · `list/2` | whoever may see the item (`Core.Access`, `:read`) |
  | `revoke/3` | the link's maker, a lead of the item's team, the system admin (`{:share_link, _}`'s `:revoke`); anyone else who sees the item is refused with §5.1's words, and anyone who does not, finds nothing |
  | `open/3` | any signed-in staff of the organisation; a customer, another organisation, an unknown, expired or revoked token: `:not_found` |

  **The token** is 32 random bytes, URL-safe Base64, shown once as
  `/s/<token>` in `create/4`'s answer; only its SHA-256 is stored.

  **What an open shows** is the item at the link's level (`Data.Vocabulary.share_levels/0`):
  `summary` a handful of fields, `details` the sheet as a staff member of
  the item's team sees it, `details_history` that and its history. The
  sheet is built for **a reader of the team** (the opener, as a member of
  the item's team at `view`), never with the opener's own reach, so a link
  shows the same to everyone and nothing a customer must not see.

  Made, opened (at most once per person per link per day, in the
  organisation's zone; the audit table is the memory) and revoked are audit
  rows (`share_link_created`, `share_link_opened`, `share_link_revoked`),
  each in the transaction of its change.
  """

  alias Core.Access
  alias Core.Audit
  alias Core.Jobs
  alias Core.Jobs.Sheet
  alias Core.Leads
  alias Core.Leads.Sheet, as: LeadSheet
  alias Core.Tasks
  alias Core.Tasks.{Cards, Histories, Person}
  alias Data.Jobs, as: JobStore
  alias Data.Leads, as: LeadStore
  alias Data.Repo
  alias Data.Scope
  alias Data.ShareLinks, as: Store
  alias Data.ShareLinks.ShareLink
  alias Data.Tasks, as: TaskStore
  alias Data.Teams
  alias Data.Vocabulary

  @expiries [1, 7, 30]

  @type subject :: {:task | :job | :lead, term()}

  # ── Making and listing ──────────────────────────────────────────────────────

  @doc """
  `POST /tasks/:id/share-links` · `POST /jobs/:id/share-links {level,
  expires_in_days?}`: a new link. Answers `{link, path}`; `path` is the only
  place the token ever appears.
  """
  @spec create(Scope.t(), subject(), map(), DateTime.t()) ::
          {:ok, %{link: ShareLink.t(), path: String.t()}} | {:error, term()}
  def create(%Scope{} = scope, {kind, id}, params, %DateTime{} = now) do
    params = Map.new(params, fn {k, v} -> {to_string(k), v} end)

    with {:ok, item} <- fetch_item(scope, kind, id),
         {:ok, level} <- level(params["level"]),
         {:ok, expires_at} <- expiry(params["expires_in_days"], now) do
      token = 32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

      attrs = %{
        organisation_id: Scope.organisation_id(scope),
        task_id: if(kind == :task, do: item.id),
        job_id: if(kind == :job, do: item.id),
        lead_id: if(kind == :lead, do: item.id),
        level: level,
        token_sha256: hash(token),
        created_by_user_id: Scope.user_id(scope),
        expires_at: expires_at
      }

      Repo.transaction(fn -> insert(scope, attrs, item, token, now) end)
    end
  end

  defp insert(scope, attrs, item, token, now) do
    case Store.create(attrs) do
      {:ok, link} ->
        {:ok, _event} =
          Audit.record(scope, "share_link_created", link, after: snapshot(link, item), now: now)

        %{link: link, path: "/s/" <> token}

      {:error, changeset} ->
        Repo.rollback(changeset)
    end
  end

  @doc "`GET /tasks/:id/share-links` · `GET /jobs/:id/share-links`: the item's links, newest first."
  @spec list(Scope.t(), subject()) :: {:ok, [ShareLink.t()]} | {:error, term()}
  def list(%Scope{} = scope, {kind, id}) do
    with {:ok, item} <- fetch_item(scope, kind, id), do: {:ok, Store.list_for({kind, item.id})}
  end

  # ── Revoking ────────────────────────────────────────────────────────────────

  @doc "`POST /share-links/:id/revoke`: the link, off for good; revoking twice keeps the first."
  @spec revoke(Scope.t(), term(), DateTime.t()) :: {:ok, ShareLink.t()} | {:error, term()}
  def revoke(%Scope{} = scope, id, %DateTime{} = now) do
    with %ShareLink{} = link <-
           Store.get(Scope.organisation_id(scope), id) || {:error, :not_found},
         {kind, item} <- item_of(link) || {:error, :not_found},
         :ok <- may_revoke(scope, link, kind, item) do
      revoke_once(scope, link, item, now)
    end
  end

  defp revoke_once(_scope, %{revoked_at: %DateTime{}} = link, _item, _now), do: {:ok, link}

  defp revoke_once(scope, link, item, now),
    do: Repo.transaction(fn -> turn_off(scope, link, item, now) end)

  defp turn_off(scope, link, item, now) do
    {:ok, revoked} = Store.revoke(link, now, Scope.user_id(scope))

    {:ok, _event} =
      Audit.record(scope, "share_link_revoked", revoked,
        before: %{"revoked_at" => nil},
        after: Map.put(snapshot(revoked, item), "revoked_at", now),
        now: now
      )

    revoked
  end

  # A refusal is words only to someone who can see the item; to anyone else
  # the link does not exist.
  defp may_revoke(scope, link, kind, item) do
    subject = %{
      organisation_id: link.organisation_id,
      created_by_user_id: link.created_by_user_id,
      team_id: team_of(item)
    }

    case Access.why_not(scope, :revoke, {:share_link, subject}) do
      {:error, {:forbidden, _words}} = refused ->
        if Access.can?(scope, :read, access_subject(kind, item)),
          do: refused,
          else: {:error, :not_found}

      decision ->
        decision
    end
  end

  # ── Opening ─────────────────────────────────────────────────────────────────

  @doc """
  `GET /shared/:token`: `{subject, level, team, shared_by, expires_at, item}`,
  the item at the link's level. Audited once per person per link per day.
  """
  @spec open(Scope.t(), String.t(), DateTime.t()) :: {:ok, map()} | {:error, term()}
  def open(%Scope{} = scope, token, %DateTime{} = now) when is_binary(token) do
    with %ShareLink{} = link <- Store.get_by_hash(hash(token)) || {:error, :not_found},
         :ok <- Access.why_not(scope, :open, {:share_link, link}),
         :ok <- live(link, now),
         {kind, item} <- item_of(link) || {:error, :not_found},
         %{} = team <- Teams.get(link.organisation_id, team_of(item)) || {:error, :not_found} do
      Repo.transaction(fn ->
        :ok = note_opening(scope, link, item, now)

        %{
          subject: kind,
          level: link.level,
          team: %{id: team.id, name: team.name},
          shared_by: Person.view(link.created_by_user),
          expires_at: link.expires_at,
          item: render(reader(scope, team.id), kind, link.level, item, now)
        }
      end)
    end
  end

  def open(_scope, _token, _now), do: {:error, :not_found}

  # Once per person per link per day: the audit table remembers.
  defp note_opening(scope, link, item, now) do
    if Store.opened_since?(link, Scope.user_id(scope), day_start(scope, now)) do
      :ok
    else
      {:ok, _event} =
        Audit.record(scope, "share_link_opened", link, after: snapshot(link, item), now: now)

      :ok
    end
  end

  defp live(%{revoked_at: %DateTime{}}, _now), do: {:error, :not_found}

  defp live(%{expires_at: %DateTime{} = at}, now) do
    if DateTime.compare(at, now) == :gt, do: :ok, else: {:error, :not_found}
  end

  defp live(_link, _now), do: :ok

  # The start of today in the organisation's zone, as an instant.
  defp day_start(scope, now) do
    zone = Tasks.zone(scope)

    with {:ok, local} <- DateTime.shift_zone(now, zone),
         {:ok, start} <- DateTime.new(DateTime.to_date(local), ~T[00:00:00], zone),
         {:ok, utc} <- DateTime.shift_zone(start, "Etc/UTC") do
      utc
    else
      _unknown_zone -> DateTime.new!(DateTime.to_date(now), ~T[00:00:00], "Etc/UTC")
    end
  end

  # A reader of the item's team: the opener, as a member of it at `view`.
  defp reader(scope, team_id) do
    settings = %{
      Teams.get_settings(team_id)
      | peer_tasks: :view,
        peer_jobs: :view,
        peer_leads: :view
    }

    %{
      scope
      | roles: %{
          Scope.no_roles()
          | teams: %{team_id => :member},
            team_settings: %{team_id => settings}
        }
    }
  end

  # ── The item at its level ───────────────────────────────────────────────────

  defp render(_reader, :task, :summary, task, _now) do
    task = TaskStore.sheet(task)

    %{
      id: task.id,
      title: task.title,
      state: task.state,
      stage: task.stage && %{id: task.stage.id, name: task.stage.name},
      priority: task.priority,
      due_at: task.due_at,
      due_on: task.due_on,
      customer:
        task.customer && %{id: task.customer.id, display_name: task.customer.display_name},
      assignees:
        task.participants
        |> Enum.filter(& &1.level)
        |> Enum.sort_by(&{&1.level != :primary, &1.user.person.display_name})
        |> Enum.map(&Person.view(&1.user)),
      author: Person.view(task.author_user),
      inserted_at: task.inserted_at
    }
  end

  defp render(reader, :task, :details, task, now), do: Cards.sheet(reader, task, now)

  defp render(reader, :task, :details_history, task, now) do
    reader |> Cards.sheet(task, now) |> Map.put(:history, Histories.list(reader, task))
  end

  defp render(_reader, :job, :summary, job, _now) do
    job = JobStore.sheet(job)

    %{
      id: job.id,
      title: job.title,
      company: job.company && %{id: job.company.id, name: job.company.name},
      source: job.source,
      status: job.status,
      workplace: job.workplace,
      engagement: job.engagement,
      money: Sheet.money(job),
      posted_on: job.posted_on,
      first_seen_at: job.first_seen_at,
      created_by: Person.view(job.created_by_user)
    }
  end

  defp render(reader, :job, :details, job, now), do: Sheet.sheet(reader, job, now)

  defp render(reader, :job, :details_history, job, now) do
    reader
    |> Sheet.sheet(job, now)
    |> Map.put(
      :history,
      for(
        e <- JobStore.trail(job),
        do: %{action: e.action, by: Person.view(e.actor_user), at: e.occurred_at}
      )
    )
  end

  defp render(_reader, :lead, :summary, lead, _now) do
    %{
      id: lead.id,
      title: lead.job.title,
      company: lead.job.company && %{id: lead.job.company.id, name: lead.job.company.name},
      profile: %{id: lead.profile.id, title: lead.profile.title},
      customer: %{id: lead.profile.customer.id, display_name: lead.profile.customer.display_name},
      state: lead.state,
      stage: lead.stage && %{name: lead.stage.name},
      outcome: lead.outcome,
      owner: Person.view(lead.owner_user),
      applied_at: lead.applied_at,
      last_activity_at: lead.last_activity_at
    }
  end

  defp render(reader, :lead, :details, lead, now), do: LeadSheet.sheet(reader, lead, now)

  # The ledger, every row: staff and customer (QP4a-20).
  defp render(reader, :lead, :details_history, lead, now) do
    reader
    |> LeadSheet.sheet(lead, now)
    |> Map.put(:history, Enum.map(LeadStore.events(lead.id), &LeadSheet.event/1))
  end

  # ── Helpers ─────────────────────────────────────────────────────────────────

  defp fetch_item(scope, :task, id), do: Tasks.fetch(scope, :read, id)
  defp fetch_item(scope, :job, id), do: Jobs.fetch(scope, :read, id)
  defp fetch_item(scope, :lead, id), do: Leads.fetch(scope, :share, id)

  defp item_of(%ShareLink{task_id: task_id} = link) when is_binary(task_id) do
    case TaskStore.get(link.organisation_id, task_id) do
      nil -> nil
      task -> {:task, task}
    end
  end

  defp item_of(%ShareLink{job_id: job_id} = link) when is_binary(job_id) do
    case JobStore.get(link.organisation_id, job_id) do
      nil -> nil
      job -> {:job, job}
    end
  end

  defp item_of(%ShareLink{lead_id: lead_id} = link) when is_binary(lead_id) do
    case LeadStore.get(link.organisation_id, lead_id) do
      nil -> nil
      lead -> {:lead, lead}
    end
  end

  defp level(nil), do: {:error, {:missing, [:level]}}

  defp level(level) do
    if to_string(level) in Vocabulary.share_levels(),
      do: {:ok, String.to_existing_atom(to_string(level))},
      else: {:error, {:invalid, %{"level" => ["is summary, details or details_history"]}}}
  end

  defp expiry(nil, _now), do: {:ok, nil}
  defp expiry("", _now), do: {:ok, nil}

  defp expiry(days, now) do
    case Integer.parse(to_string(days)) do
      {n, ""} when n in @expiries -> {:ok, DateTime.add(now, n, :day)}
      _other -> {:error, {:invalid, %{"expires_in_days" => ["is 1, 7 or 30, or none"]}}}
    end
  end

  defp access_subject(:lead, lead), do: {:lead, Leads.subject(lead)}
  defp access_subject(kind, item), do: {kind, item}

  defp team_of(%Data.Leads.Lead{job: job}), do: job.team_id
  defp team_of(item), do: item.team_id

  defp hash(token), do: :crypto.hash(:sha256, token)

  defp snapshot(link, item) do
    %{
      "task_id" => link.task_id,
      "job_id" => link.job_id,
      "lead_id" => link.lead_id,
      "team_id" => team_of(item),
      "level" => to_string(link.level),
      "expires_at" => link.expires_at && DateTime.to_iso8601(link.expires_at)
    }
  end
end
