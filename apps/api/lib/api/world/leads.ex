defmodule Api.World.Leads do
  @moduledoc """
  P4a's run leads in `mix aq.world` (AQ-04B §12), over HTTP as the people
  who made them, from `apps/api/priv/world/p4a-snapshot.json` (taken from
  the dev database after P4a's run). The P3 world is already made; this
  step brings it to where P4a's run left it, then makes its thirteen leads.

  1. **The customers:** Naveed active again, Tanweer also in Frontend squad
     (Hira, a lead of both).
  2. **The pool:** the jobs P4a's run added (Bamboo's evening link) by their
     creators, and the Kestrel → Plover merge by whoever merged it.
  3. **The levels:** `peer_leads: edit` in both teams while the leads are
     replayed (Muaz moved a teammate's lead at `edit` in the run), then the
     teams' settings as the snapshot has them.
  4. **The leads and Employment version 2, in the run's order:** a lead made
     before Hira's *Recruiter call* / *Reference check* edit stays on
     version 1, the rest are on version 2. Each lead is made by its first
     event's actor (`POST /leads`, saved or applied, `applied_at` as the
     ledger dated it — "16 Oct" for Bamboo's morning lead) and then moved
     through its ledger's verbs in order: apply, *I applied* (Tanweer, from
     the portal), apply again with its reason, stage moves, hold and resume,
     finish, reopen, assign, archive and unarchive. Then the pin as the
     snapshot has it. Each lead's final state, stage, outcome, pin, archive,
     owner and pipeline version are checked against the snapshot; a
     mismatch stops the run.
  5. **The share link** on the Corvid lead, by whoever made it.

  Ids in the snapshot are the old database's: users map by email, teams by
  name, customers by name, profiles by customer and title, companies by
  name, jobs by team and canonical key (read back from the new database).
  """

  import Ecto.Query, only: [from: 2]

  alias Api.World.{Http, Snapshot}
  alias Data.Repo

  @team "/team/v1"
  @client "/client/v1"
  @not_sent ~w(team_id source source_url canonical_key source_job_id origin first_seen_at
               last_seen_at created_by_user_id company_id status closed_at closed_by_user_id
               close_reason last_activity_at archived_at archived_by_user_id description_html)

  @doc "Runs every part, answering `w` with `w.leads` (old id → new id)."
  def run(w, p3) do
    s = %{p3: p3, p4: Snapshot.load("p4a-snapshot.json")}

    w
    |> Map.put(:leads, %{})
    |> customers(s)
    |> jobs(s)
    |> merges(s)
    |> levels(s, :edit)
    |> leads(s)
    |> levels(s, :snapshot)
    |> share_links(s)
  end

  # ── 1. The customers ────────────────────────────────────────────────────────

  defp customers(w, s) do
    hira = who(s, by_email(s, "hira@example.com"))

    for c <- s.p4["customers"] do
      id = customer(w, s, c["id"])
      now = Repo.one(from(x in Data.Customers.Customer, where: x.id == ^id, select: x.status))

      if to_string(now) != c["status"] and c["status"] in ~w(active paused ended),
        do: Http.call(w, hira, :post, "#{@team}/customers/#{id}/status", %{status: c["status"]})

      for ct <- s.p4["customer_teams"],
          ct["customer_id"] == c["id"],
          do: serve(w, hira, id, team(w, s, ct["team_id"]))
    end

    w
  end

  defp serve(w, hira, id, team) do
    served? =
      Repo.exists?(
        from(x in Data.Customers.CustomerTeam, where: x.customer_id == ^id and x.team_id == ^team)
      )

    unless served?,
      do: Http.call(w, hira, :post, "#{@team}/customers/#{id}/teams", %{team_id: team})
  end

  # ── 2. The pool ─────────────────────────────────────────────────────────────

  defp jobs(w, s) do
    merged = for m <- s.p4["job_merges"], do: {m["team_id"], m["from_canonical_key"]}

    for job <- Snapshot.rows(s.p4, "jobs"),
        {job["team_id"], job["canonical_key"]} not in merged,
        is_nil(job_id(w, s, job["team_id"], job["canonical_key"])) do
      body =
        job
        |> Snapshot.writable(@not_sent)
        |> Map.merge(%{
          "team_id" => team(w, s, job["team_id"]),
          "url" => job["source_url"],
          "company_id" => company(w, s, job["company_id"])
        })
        |> Map.reject(fn {_k, v} -> is_nil(v) end)

      Http.call(w, who(s, job["created_by_user_id"]), :post, @team <> "/jobs", body)
    end

    w
  end

  defp merges(w, s) do
    for m <- Snapshot.rows(s.p4, "job_merges") do
      team = team(w, s, m["team_id"])

      done? =
        Repo.exists?(
          from(x in Data.Jobs.Merge,
            where: x.team_id == ^team and x.from_canonical_key == ^m["from_canonical_key"]
          )
        )

      unless done? do
        into = Snapshot.row!(s.p4, "jobs", m["into_job_id"])
        into_id = job_id(w, s, into["team_id"], into["canonical_key"])
        who = who(s, m["merged_by_user_id"])

        from_id =
          job_id(w, s, m["team_id"], m["from_canonical_key"]) ||
            Http.call(w, who, :post, @team <> "/jobs", %{
              team_id: team,
              url: m["from_source_url"],
              title: m["from_title"]
            })["id"]

        Http.call(w, who, :post, "#{@team}/jobs/#{from_id}/merge", %{into_job_id: into_id})
      end
    end

    w
  end

  # ── 3. The levels ───────────────────────────────────────────────────────────

  defp levels(w, s, :edit) do
    for t <- s.p4["teams"],
        do:
          Http.call(w, w.admin, :put, "#{@team}/teams/#{team(w, s, t["id"])}/settings", %{
            peer_leads: "edit"
          })

    w
  end

  defp levels(w, s, :snapshot) do
    for ts <- s.p4["team_settings"] do
      body =
        Map.take(ts, ~w(peer_tasks peer_leads peer_jobs customer_sees_staff_names
                        customer_sees_conversations customer_sees_job_suggestions))

      Http.call(w, w.admin, :put, "#{@team}/teams/#{team(w, s, ts["team_id"])}/settings", body)
    end

    w
  end

  # ── 4. The leads, with Employment version 2 where the run made it ───────────

  defp leads(w, s) do
    versions =
      for v <- s.p4["pipeline_versions"], v["number"] > 1, do: {v["inserted_at"], {:version, v}}

    leads = for l <- s.p4["leads"], do: {l["inserted_at"], {:lead, l}}

    (versions ++ leads)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce(w, fn
      {_at, {:version, v}}, w -> version(w, s, v)
      {_at, {:lead, l}}, w -> lead(w, s, l)
    end)
  end

  defp version(w, s, v) do
    live = Http.call(w, w.admin, :get, "#{@team}/pipelines/#{v["pipeline_key"]}")
    keys = Enum.map(live["stages"], & &1["key"])

    stages =
      for st <- Enum.sort_by(s.p4["pipeline_stages"], & &1["position"]),
          st["pipeline_version_id"] == v["id"] do
        %{name: st["name"], kind: st["kind"], anchor_kind: st["anchor_kind"]}
        |> then(&if(st["key"] in keys, do: Map.put(&1, :key, st["key"]), else: &1))
      end

    Http.call(
      w,
      who(s, v["created_by_user_id"]),
      :put,
      "#{@team}/pipelines/#{v["pipeline_key"]}",
      %{
        stages: stages
      }
    )

    w
  end

  defp lead(w, s, l) do
    [first | rest] =
      s.p4["lead_events"]
      |> Enum.filter(&(&1["lead_id"] == l["id"]))
      |> Enum.sort_by(&{&1["occurred_at"], &1["recorded_at"]})

    sheet = make(w, s, l, first)
    sheet = Enum.reduce(rest, sheet, &replay(w, s, l, &1, &2))
    sheet = keep(w, s, l, sheet)
    check!(s, l, sheet)
    %{w | leads: Map.put(w.leads, l["id"], sheet["id"])}
  end

  defp make(w, s, l, first) do
    as = if first["kind"] == "applied", do: "apply", else: "save"
    version = Snapshot.row!(s.p4, "pipeline_versions", l["pipeline_version_id"])
    job = Snapshot.row!(s.p4, "jobs", l["job_id"])

    body =
      %{
        job_id: job_id(w, s, job["team_id"], job["canonical_key"]),
        profile_id: profile(w, s, l["profile_id"]),
        as: as,
        pipeline_key: version["pipeline_key"]
      }
      |> Map.merge(if as == "apply", do: applied(l, first), else: %{})

    Http.call(w, who(s, first["actor_user_id"]), :post, @team <> "/leads", body)
  end

  defp applied(l, event) do
    %{applied_at: event["occurred_at"], applied_via: l["applied_via"]}
    |> Map.reject(fn {_k, v} -> is_nil(v) end)
  end

  # One ledger row, as the verb that wrote it, by whoever did it.
  defp replay(w, s, l, e, sheet) do
    actor = who(s, e["actor_user_id"])
    path = "#{@team}/leads/#{sheet["id"]}"
    from = %{state: sheet["state"], stage: sheet["stage"] && sheet["stage"]["key"]}

    case step(w, s, l, e, sheet, from) do
      nil ->
        sheet

      {:client, body} ->
        Http.call(w, actor, :post, "#{@client}/leads/#{sheet["id"]}/applied", body)
        Http.call(w, w.admin, :get, path)

      {verb, body} ->
        Http.call(w, actor, :post, path <> "/" <> verb, body)
    end
  end

  defp step(_w, _s, _l, %{"kind" => "applied", "actor_kind" => "customer"}, _sheet, from),
    do: {:client, %{from: from}}

  defp step(_w, _s, _l, %{"kind" => "applied", "is_again" => true} = e, _sheet, from),
    do: {"apply-again", %{from: from, reason: e["note"]}}

  defp step(_w, _s, l, %{"kind" => "applied"} = e, _sheet, from),
    do: {"apply", Map.merge(%{from: from}, applied(l, e))}

  defp step(_w, _s, _l, %{"kind" => "stage_moved"} = e, sheet, from),
    do: {"move", %{from: from, state: "in_progress", stage: stage_key(sheet, e["to_label"])}}

  defp step(_w, _s, l, %{"kind" => "state_moved", "to_label" => "On hold"} = e, _sheet, from),
    do: {"hold", %{from: from, hold_reason: e["note"], hold_until_on: l["hold_until_on"]}}

  defp step(_w, _s, _l, %{"kind" => "state_moved"}, _sheet, from), do: {"resume", %{from: from}}

  defp step(_w, _s, _l, %{"kind" => "outcome_set"} = e, _sheet, from),
    do: {"finish", %{from: from, outcome: e["outcome"]}}

  defp step(_w, _s, _l, %{"kind" => "reopened"}, _sheet, from), do: {"reopen", %{from: from}}

  defp step(w, s, l, %{"kind" => "owner_changed"}, _sheet, _from),
    do: {"assign", %{owner_user_id: Map.fetch!(w.users, who(s, l["owner_user_id"]))}}

  defp step(_w, _s, _l, %{"kind" => "pipeline_changed"}, _sheet, from),
    do: {"pipeline", %{from: from}}

  defp step(_w, _s, _l, %{"kind" => "archived"}, _sheet, _from), do: {"archive", %{}}
  defp step(_w, _s, _l, %{"kind" => "unarchived"}, _sheet, _from), do: {"unarchive", %{}}
  defp step(_w, _s, _l, _e, _sheet, _from), do: nil

  # The pin as the snapshot has it (Hired pinned itself on the way), then the archive.
  defp keep(w, s, l, sheet) do
    owner = who(s, l["owner_user_id"])
    path = "#{@team}/leads/#{sheet["id"]}"

    sheet =
      cond do
        l["is_pinned"] and not sheet["is_pinned"] -> Http.call(w, owner, :post, path <> "/pin")
        sheet["is_pinned"] and not l["is_pinned"] -> Http.call(w, owner, :post, path <> "/unpin")
        true -> sheet
      end

    if l["archived_at"] && is_nil(sheet["archived_at"]),
      do: Http.call(w, owner, :post, path <> "/archive"),
      else: sheet
  end

  defp check!(s, l, sheet) do
    stage = l["stage_id"] && Snapshot.row!(s.p4, "pipeline_stages", l["stage_id"])["key"]
    version = Snapshot.row!(s.p4, "pipeline_versions", l["pipeline_version_id"])
    owner = Snapshot.row!(s.p4, "users", l["owner_user_id"])["email"]

    want = %{
      state: l["state"],
      stage: stage,
      outcome: l["outcome"],
      pinned: l["is_pinned"],
      archived: not is_nil(l["archived_at"]),
      owner: owner,
      pipeline: {version["pipeline_key"], version["number"]}
    }

    got = %{
      state: sheet["state"],
      stage: sheet["stage"] && sheet["stage"]["key"],
      outcome: sheet["outcome"],
      pinned: sheet["is_pinned"],
      archived: not is_nil(sheet["archived_at"]),
      owner: owner_email(sheet),
      pipeline: {sheet["pipeline"]["key"], sheet["pipeline"]["version"]}
    }

    if want != got,
      do: Mix.raise("lead #{l["id"]} ended as #{inspect(got)}, not #{inspect(want)}")
  end

  defp owner_email(sheet) do
    id = sheet["owner"]["user_id"]
    Repo.one(from(u in Data.Accounts.User, where: u.id == ^id, select: u.email))
  end

  defp stage_key(sheet, name) do
    case Enum.find(sheet["pipeline"]["stages"], &(&1["name"] == name)) do
      nil -> Mix.raise("no stage #{inspect(name)} in #{inspect(sheet["pipeline"]["key"])}")
      stage -> stage["key"]
    end
  end

  # ── 5. The share link ───────────────────────────────────────────────────────

  defp share_links(w, s) do
    for link <- s.p4["share_links"], link["lead_id"], is_nil(link["revoked_at"]) do
      days =
        if link["expires_at"] do
          {:ok, ends, _} = DateTime.from_iso8601(link["expires_at"])
          {:ok, made, _} = DateTime.from_iso8601(link["inserted_at"])
          days = DateTime.diff(ends, made, :second) / 86_400
          Enum.min_by([1, 7, 30], &abs(&1 - days))
        end

      body =
        %{level: link["level"], expires_in_days: days} |> Map.reject(fn {_k, v} -> is_nil(v) end)

      lead = Map.fetch!(w.leads, link["lead_id"])

      Http.call(
        w,
        who(s, link["created_by_user_id"]),
        :post,
        "#{@team}/leads/#{lead}/share-links",
        body
      )
    end

    w
  end

  # ── Ids, old to new ─────────────────────────────────────────────────────────

  # A P4a user id as the world knows its person: P3's id, by email.
  defp who(_s, nil), do: nil
  defp who(s, id), do: Snapshot.user_by_email(s.p3, Snapshot.row!(s.p4, "users", id)["email"])

  defp by_email(s, email), do: Snapshot.user_by_email(s.p4, email)

  defp team(w, s, id) do
    name = Snapshot.row!(s.p4, "teams", id)["name"]
    Map.fetch!(w.teams, Enum.find(s.p3["teams"], &(&1["name"] == name))["id"])
  end

  defp customer(w, s, id) do
    name = Snapshot.row!(s.p4, "customers", id)["display_name"]
    Map.fetch!(w.customers, Enum.find(s.p3["customers"], &(&1["display_name"] == name))["id"])
  end

  defp profile(w, s, id) do
    p = Snapshot.row!(s.p4, "profiles", id)
    name = Snapshot.row!(s.p4, "customers", p["customer_id"])["display_name"]
    customer = Enum.find(s.p3["customers"], &(&1["display_name"] == name))["id"]

    old =
      Enum.find(s.p3["profiles"], &(&1["customer_id"] == customer and &1["title"] == p["title"]))

    Map.fetch!(w.profiles, old["id"])
  end

  defp company(_w, _s, nil), do: nil

  defp company(w, s, id) do
    name = Snapshot.row!(s.p4, "companies", id)["name"]
    Map.fetch!(w.companies, Enum.find(s.p3["companies"], &(&1["name"] == name))["id"])
  end

  defp job_id(w, s, team_id, key) do
    team = team(w, s, team_id)

    Repo.one(
      from(j in Data.Jobs.Job,
        where: j.team_id == ^team and j.canonical_key == ^key,
        select: j.id
      )
    )
  end
end
