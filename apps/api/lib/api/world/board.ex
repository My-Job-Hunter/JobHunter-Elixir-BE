defmodule Api.World.Board do
  @moduledoc """
  P2's tasks in `mix aq.world` (AQ-03B §8), each in its team (a task the
  snapshot left without one goes to its author's first team), over HTTP as
  each person: Fiza's stages; the nine tasks by their authors — staff in
  the console, Tanweer in the portal — with their people, steps and
  checklist; the customer's file, ticks, step and *Mark done*; comments and
  replies by their authors; the link and the relation; and each state
  reached with its verbs (start, then hold with the reason).

  Who acts where the snapshot does not say: a task's primary assignee (else
  its author) moves it; a team's lead puts people on a customer's task when
  the portal's routing put others on it.
  """

  alias Api.World.Http
  alias Api.World.People
  alias Api.World.Snapshot

  @team "/team/v1"
  @client "/client/v1"

  @doc "Fiza's (and anyone's) own stages, in their order."
  def stages(w, snap) do
    snap
    |> Snapshot.rows("task_stages")
    |> Enum.sort_by(&{&1["user_id"], &1["position"]})
    |> Enum.each(&Http.call(w, &1["user_id"], :post, @team <> "/me/stages", %{name: &1["name"]}))

    w
  end

  @doc "Every task, oldest first, with its parts and its state."
  def tasks(w, snap) do
    w =
      Enum.reduce(Snapshot.rows(snap, "tasks"), w, fn task, w ->
        sheet = create(w, snap, task)
        w = %{w | tasks: Map.put(w.tasks, task["id"], sheet["id"])}
        people(w, snap, task, sheet)
        w
      end)

    w
    |> customer_parts(snap)
    |> comments(snap)
    |> links(snap)
    |> states(snap)
  end

  # ── Making a task ───────────────────────────────────────────────────────────

  defp create(w, _snap, %{"source" => "customer"} = task) do
    body =
      %{title: task["title"], description: task["description"], due_on: task["due_on"]}
      |> Map.put(:profile_id, task["profile_id"] && w.profiles[task["profile_id"]])
      |> Map.reject(fn {_k, v} -> is_nil(v) end)

    Http.call(w, task["author_user_id"], :post, @client <> "/tasks", body)
  end

  defp create(w, snap, task) do
    {primary, secondary} = assignees(w, snap, task)

    body =
      task
      |> Map.take(~w(title description priority due_at due_on reminder_minutes customer_access))
      |> Map.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.merge(%{
        "team_id" => w.teams[task["team_id"]] || first_team(w, snap, task["author_user_id"]),
        "customer_id" => task["customer_id"] && w.customers[task["customer_id"]],
        "profile_id" => task["profile_id"] && w.profiles[task["profile_id"]],
        "primary_user_id" => primary,
        "secondary_user_ids" => secondary,
        "checklist" => checklist(snap, task),
        "steps" => steps_for(w, snap, task)
      })
      |> Map.reject(fn {_k, v} -> is_nil(v) end)

    Http.call(w, task["author_user_id"], :post, @team <> "/tasks", body)
  end

  defp assignees(w, snap, task) do
    rows = for p <- snap["task_participants"], p["task_id"] == task["id"], p["level"], do: p
    primary = Enum.find_value(rows, &(&1["level"] == "primary" && w.users[&1["user_id"]]))
    secondary = for p <- rows, p["level"] == "secondary", do: w.users[p["user_id"]]
    {primary, secondary}
  end

  defp checklist(snap, task) do
    for i <- Enum.sort_by(snap["task_checklist_items"], & &1["position"]),
        i["task_id"] == task["id"],
        do: i["text"]
  end

  defp steps_for(w, snap, task) do
    for s <- Enum.sort_by(snap["task_steps"], & &1["position"]), s["task_id"] == task["id"] do
      %{
        title: s["title"],
        is_for_customer: s["is_for_customer"],
        assignee_user_id: s["assignee_user_id"] && w.users[s["assignee_user_id"]]
      }
    end
  end

  # The people the snapshot has on a customer's task, when the portal's
  # routing put others on it: set by the team's lead.
  defp people(w, snap, %{"source" => "customer"} = task, sheet) do
    {primary, secondary} = assignees(w, snap, task)
    now = sheet["people"] || []

    had =
      {Enum.find_value(now, &(&1["level"] == "primary" && &1["user_id"])),
       Enum.sort(for p <- now, p["level"] == "secondary", do: p["user_id"])}

    if had != {primary, Enum.sort(secondary)} do
      lead = lead_of(snap, task["team_id"])

      Http.call(w, lead, :put, "#{@team}/tasks/#{sheet["id"]}/assignees", %{
        primary_user_id: primary,
        secondary_user_ids: secondary
      })
    end
  end

  defp people(_w, _snap, _task, _sheet), do: :ok

  # ── The customer's part: the file, the ticks, the step, done ────────────────

  defp customer_parts(w, snap) do
    for tm <- snap["task_media"] do
      media = Snapshot.row!(snap, "media", tm["media_id"])
      who = tm["added_by_user_id"]
      prefix = if customer?(snap, who), do: @client, else: @team
      media_id = People.upload(w, who, prefix, media)

      Http.call(w, who, :post, "#{prefix}/tasks/#{w.tasks[tm["task_id"]]}/files", %{
        media_id: media_id
      })
    end

    for i <- snap["task_checklist_items"], i["checked_by_user_id"] do
      toggle(w, snap, i["checked_by_user_id"], i["task_id"], "checklist", i["position"])
    end

    for s <- snap["task_steps"], s["done_by_user_id"] do
      toggle(w, snap, s["done_by_user_id"], s["task_id"], "steps", s["position"])
    end

    w
  end

  defp toggle(w, snap, who, old_task, part, position) do
    task = w.tasks[old_task]
    prefix = if customer?(snap, who), do: @client, else: @team
    sheet = Http.call(w, who, :get, "#{prefix}/tasks/#{task}")
    item = Enum.find(sheet[part], &(&1["position"] == position))
    segment = if part == "checklist", do: "checklist", else: "steps"
    Http.call(w, who, :post, "#{prefix}/tasks/#{task}/#{segment}/#{item["id"]}/toggle", %{})
  end

  # ── The thread ──────────────────────────────────────────────────────────────

  defp comments(w, snap) do
    thread =
      Enum.map(snap["task_comments"], &{:comment, &1}) ++
        Enum.map(snap["task_comment_replies"], &{:reply, &1})

    thread
    |> Enum.sort_by(fn {_kind, row} -> row["inserted_at"] end)
    |> Enum.reduce(w, fn {kind, row}, w -> say(w, snap, kind, row) end)
  end

  defp say(w, snap, kind, row) do
    who = row["author_user_id"]
    task = w.tasks[row["task_id"]]
    customer? = customer?(snap, who)
    prefix = if customer?, do: @client, else: @team

    body =
      if customer?,
        do: %{body: row["body"]},
        else: %{
          body: row["body"],
          is_staff_only: row["is_staff_only"],
          mention_user_ids: mentions(w, snap, row["body"])
        }

    path =
      case kind do
        :comment -> "#{prefix}/tasks/#{task}/comments"
        :reply -> "#{prefix}/tasks/#{task}/comments/#{w.comments[row["comment_id"]]}/replies"
      end

    thread = Http.call(w, who, :post, path, body)

    if kind == :comment do
      made = thread |> Enum.filter(&(&1["body"] == row["body"])) |> List.last()
      %{w | comments: Map.put(w.comments, row["id"], made["id"])}
    else
      w
    end
  end

  # "@Qasim" names the staff member whose display name begins with Qasim.
  defp mentions(w, snap, body) do
    for [_at, first] <- Regex.scan(~r/@(\w+)/u, body || ""),
        user <- snap["users"],
        not customer?(snap, user["id"]),
        String.starts_with?(Snapshot.name(snap, user["id"]), first),
        do: w.users[user["id"]]
  end

  # ── Links and relations ─────────────────────────────────────────────────────

  defp links(w, snap) do
    for l <- Snapshot.rows(snap, "task_links") do
      body = %{url: l["url"], label: l["label"]}

      Http.call(
        w,
        l["added_by_user_id"],
        :post,
        "#{@team}/tasks/#{w.tasks[l["task_id"]]}/links",
        body
      )
    end

    for r <- Snapshot.rows(snap, "task_relations") do
      body = %{task_id: w.tasks[r["to_task_id"]], kind: r["kind"]}

      Http.call(
        w,
        r["created_by_user_id"],
        :post,
        "#{@team}/tasks/#{w.tasks[r["from_task_id"]]}/relations",
        body
      )
    end

    w
  end

  # ── The states, by their verbs ──────────────────────────────────────────────

  defp states(w, snap) do
    for task <- Snapshot.rows(snap, "tasks"), task["state"] not in ["todo", "draft"] do
      state(w, snap, task)
    end

    w
  end

  defp state(w, snap, %{"state" => "done", "done_by_user_id" => who} = task) do
    prefix = if customer?(snap, who), do: @client, else: @team
    Http.call(w, who, :post, "#{prefix}/tasks/#{w.tasks[task["id"]]}/done", %{from: "todo"})
  end

  defp state(w, snap, %{"state" => "on_hold"} = task) do
    who = mover(snap, task)
    id = w.tasks[task["id"]]
    Http.call(w, who, :post, "#{@team}/tasks/#{id}/start", %{from: "todo"})

    Http.call(w, who, :post, "#{@team}/tasks/#{id}/hold", %{
      from: "in_progress",
      reason: task["hold_reason"]
    })
  end

  defp state(w, snap, %{"state" => "in_progress"} = task) do
    Http.call(w, mover(snap, task), :post, "#{@team}/tasks/#{w.tasks[task["id"]]}/start", %{
      from: "todo"
    })
  end

  defp state(w, snap, %{"state" => "closed"} = task) do
    who = task["closed_by_user_id"] || mover(snap, task)
    body = %{from: "todo", reason: task["closed_reason"], note: task["closed_note"]}
    Http.call(w, who, :post, "#{@team}/tasks/#{w.tasks[task["id"]]}/close", body)
  end

  # The primary assignee, else the author when they are staff.
  defp mover(snap, task) do
    primary =
      Enum.find(
        snap["task_participants"],
        &(&1["task_id"] == task["id"] and &1["level"] == "primary")
      )

    (primary && primary["user_id"]) || task["author_user_id"]
  end

  # ── Helpers ─────────────────────────────────────────────────────────────────

  defp customer?(snap, user_id), do: Enum.any?(snap["customers"], &(&1["user_id"] == user_id))

  defp first_team(w, snap, user_id) do
    snap
    |> Snapshot.rows("team_members")
    |> Enum.filter(&(&1["user_id"] == user_id))
    |> Enum.map(&Snapshot.row!(snap, "teams", &1["team_id"]))
    |> Enum.sort_by(& &1["name"])
    |> List.first()
    |> then(&(&1 && w.teams[&1["id"]]))
  end

  defp lead_of(snap, team_id) do
    snap
    |> Snapshot.rows("team_members")
    |> Enum.sort_by(& &1["joined_at"])
    |> Enum.filter(&(&1["team_id"] == team_id and &1["role"] == "lead"))
    |> List.last()
    |> Map.fetch!("user_id")
  end
end
