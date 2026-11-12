defmodule Api.World.Pool do
  @moduledoc """
  P3's pool in `mix aq.world` (AQ-03B §8), over HTTP as each person: the 29
  companies by whoever added them; the 30 jobs in **Backend squad**'s pool
  by their `created_by`, with their skills, platform details and the
  snapshot's text; the merge (the merged job is not in the snapshot —
  `job_merges` keeps its key, link and title — so it is made again from
  that and merged by whoever merged it); the dismissal; GiveDirectly's job
  closed and reopened; Ostrava's archived and unarchived; and three jobs
  in **Frontend squad**'s pool added by Hira, one of them a link Backend
  squad also holds.
  """

  alias Api.World.Http
  alias Api.World.People
  alias Api.World.Snapshot

  @team "/team/v1"

  # The job's own columns a write sends; identity, status and the verbs'
  # columns are the server's.
  @not_sent ~w(team_id source source_url canonical_key source_job_id origin first_seen_at
               last_seen_at created_by_user_id company_id status closed_at closed_by_user_id
               close_reason last_activity_at archived_at archived_by_user_id description_html)
  @details ~w(job_linkedin_details job_upwork_details job_indeed_details job_yc_details)

  @frontend [
    {"https://careers.bambooinvest.co.uk/jobs/111", "Backend Developer", "Bamboo Invest"},
    {"https://mosaiclearning.example/careers/vue-engineer", "Senior Vue.js Engineer",
     "Mosaic Learning"},
    {"https://jobs.ashbyhq.com/juniperedge/8c4f2a71", "Frontend Engineer (React)", "Juniper Edge"}
  ]

  @doc "The companies, by whoever added each."
  def companies(w, snap) do
    Enum.reduce(Snapshot.rows(snap, "companies"), w, fn c, w ->
      body = Snapshot.writable(c, ~w(name_normalized created_by_user_id))
      made = Http.call(w, c["created_by_user_id"], :post, @team <> "/companies", body)
      %{w | companies: Map.put(w.companies, c["id"], made["id"])}
    end)
  end

  @doc "The jobs, oldest first, each by its creator in Backend squad's pool (every P3 job's)."
  def jobs(w, snap) do
    backend = backend(w, snap)

    Enum.reduce(Snapshot.rows(snap, "jobs"), w, fn job, w ->
      body =
        job
        |> Snapshot.writable(@not_sent)
        |> Map.merge(%{
          "team_id" => backend,
          "url" => job["source_url"],
          "company_id" => job["company_id"] && w.companies[job["company_id"]],
          "skills" => skills(w, snap, job),
          "platform_details" => details(snap, job),
          "snapshot_text" => snapshot_text(snap, job)
        })
        |> Map.reject(fn {_k, v} -> is_nil(v) end)

      made = Http.call(w, job["created_by_user_id"], :post, @team <> "/jobs", body)
      %{w | jobs: Map.put(w.jobs, job["id"], made["id"])}
    end)
  end

  @doc "Each merge: the merged job made again from `job_merges`, then merged into its survivor."
  def merges(w, snap) do
    for m <- Snapshot.rows(snap, "job_merges") do
      survivor = Snapshot.row!(snap, "jobs", m["into_job_id"])
      who = m["merged_by_user_id"]

      merged =
        Http.call(w, who, :post, @team <> "/jobs", %{
          team_id: backend(w, snap),
          url: m["from_source_url"],
          title: m["from_title"],
          company_id: survivor["company_id"] && w.companies[survivor["company_id"]]
        })

      into = w.jobs[m["into_job_id"]]
      Http.call(w, who, :post, "#{@team}/jobs/#{merged["id"]}/merge", %{into_job_id: into})
    end

    w
  end

  @doc "Each dismissal, by whoever dismissed it."
  def dismissals(w, snap) do
    for d <- Snapshot.rows(snap, "job_dismissals") do
      Http.call(
        w,
        d["dismissed_by_user_id"],
        :post,
        "#{@team}/jobs/#{w.jobs[d["job_id"]]}/dismissals",
        %{
          profile_id: w.profiles[d["profile_id"]],
          reason: d["reason"],
          note: d["note"]
        }
      )
    end

    w
  end

  @doc "GiveDirectly's job closed and reopened by its creator; Ostrava's archived and unarchived by a lead."
  def verbs(w, snap) do
    given = job_of(snap, "GiveDirectly")
    id = w.jobs[given["id"]]
    who = given["created_by_user_id"]
    Http.call(w, who, :post, "#{@team}/jobs/#{id}/close", %{from: "open", reason: "filled"})
    Http.call(w, who, :post, "#{@team}/jobs/#{id}/reopen", %{from: "closed"})

    ostrava = w.jobs[job_of(snap, "Ostrava Systems")["id"]]
    hira = Snapshot.user_by_email(snap, "hira@example.com")
    Http.call(w, hira, :post, "#{@team}/jobs/#{ostrava}/archive")
    Http.call(w, hira, :post, "#{@team}/jobs/#{ostrava}/unarchive")
    w
  end

  @doc "Three jobs in Frontend squad's pool by Hira; the first is a link Backend squad holds too."
  def frontend(w, snap) do
    hira = Snapshot.user_by_email(snap, "hira@example.com")
    frontend = team(w, snap, "Frontend squad")

    for {url, title, company} <- @frontend do
      check = Http.call(w, hira, :post, @team <> "/jobs/check", %{team_id: frontend, url: url})

      if check["state"] != "new",
        do: Mix.raise("#{url} is not new in Frontend squad: #{inspect(check)}")

      Http.call(w, hira, :post, @team <> "/jobs", %{
        team_id: frontend,
        url: url,
        title: title,
        company_id: w.companies[company_id(snap, company)]
      })
    end

    w
  end

  # ── Helpers ─────────────────────────────────────────────────────────────────

  defp skills(w, snap, job) do
    for s <- snap["job_skills"], s["job_id"] == job["id"] do
      %{skill_id: People.skill_id(w, snap, s["skill_id"]), is_required: s["is_required"]}
    end
  end

  defp details(snap, job) do
    Enum.find_value(@details, fn table ->
      case Enum.find(snap[table] || [], &(&1["job_id"] == job["id"])) do
        nil -> nil
        row -> Snapshot.writable(row, ["job_id"])
      end
    end)
  end

  defp snapshot_text(snap, job) do
    case Enum.find(snap["job_snapshots"], &(&1["job_id"] == job["id"])) do
      nil -> nil
      s -> s["body"]
    end
  end

  defp job_of(snap, company),
    do: Enum.find(snap["jobs"], &(&1["company_id"] == company_id(snap, company)))

  defp company_id(snap, name), do: Enum.find(snap["companies"], &(&1["name"] == name))["id"]

  defp backend(w, snap), do: team(w, snap, "Backend squad")

  defp team(w, snap, name), do: w.teams[Enum.find(snap["teams"], &(&1["name"] == name))["id"]]
end
