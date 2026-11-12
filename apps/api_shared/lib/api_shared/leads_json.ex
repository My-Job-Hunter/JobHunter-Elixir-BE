defmodule ApiShared.LeadsJSON do
  @moduledoc """
  The leads' shapes (AQ-04A §8.3, §8.4), pinned before the build so both
  repos build to one contract: the stage, the pipeline, the card, the
  board, the job's panel row, the sheet, the event, the check's lead half,
  and the customer's row, sheet, list and suggestion. `Core.Leads.Sheet`,
  `Core.Leads.Board`, `Core.Leads.Guard` and `Core.Leads.Portal` build them
  (the customer's view is cut there, in the context); this module lists
  every field by name, so nothing reaches the wire unasked. Keys are
  snake_case and **no map is keyed by data**. P4b (AQ-04B §8.4) adds the card's and
  sheet's `next`, `follow_up`, `quiet`, `labels`, the sheet's `tasks`,
  `notes_count`, `archive_reason`, the board's `lane` and `lanes`, and the note,
  label, saved view, Tracker row, preview, History page and bulk answer.
  """

  alias ApiShared.JobsJSON

  @person ~w(user_id name photo_url)a
  @stage ~w(key name kind anchor_kind position)a
  @card ~w(id team state stage progress outcome priority is_pinned archived_at job profile customer
           owner last_activity_at hold_until_on resume_due next follow_up quiet labels)a
  @sheet_facts ~w(applied_at applied_by applied_via applied_confirmation cv cover_letter_md bid
                  connects_spent expectation hold_reason held_at outcome_note finished_at pipeline
                  job recent created_by can tasks notes_count archive_reason recruiters tabs
                  banner)a
  @row ~w(id profile customer owner state stage outcome applied_at last_activity_at)a
  @can ~w(apply apply_again move hold resume finish reopen archive unarchive pin unpin assign cv
          pipeline edit share)a
  @money ~w(min_minor max_minor currency period source is_estimate is_undisclosed text)a

  @doc "A stage: `{key, name, kind, anchor_kind, position}` (+ `retired` on the board's retired columns)."
  def stage(nil), do: nil

  def stage(s) do
    base = Map.take(s, @stage)
    if Map.get(s, :retired), do: Map.put(base, :retired, true), else: base
  end

  @doc "A pipeline: `{key, name, version, stages, can_edit}`."
  def pipeline(p) do
    %{
      key: p.key,
      name: p.name,
      version: p.version,
      stages: Enum.map(p.stages, &stage/1),
      can_edit: p.can_edit
    }
  end

  @doc """
  The boards' card; P4b adds `next`, `follow_up: {state, count, of}`,
  `quiet: {since, archives_on, days_left, warn}` and `labels: [{id, name}]` (AQ-04B §8.1).
  """
  def card(c) do
    c
    |> Map.take(@card)
    |> Map.update!(:stage, &stage/1)
    |> Map.update!(:owner, &person/1)
    |> Map.update!(:job, fn job -> Map.update!(job, :money, &Map.take(&1, @money)) end)
    |> update(:next, &next/1)
  end

  defp update(map, key, fun) do
    case Map.fetch(map, key) do
      {:ok, value} -> Map.put(map, key, fun.(value))
      :error -> map
    end
  end

  @doc "*Next* (§8.4): `{kind, words, at, task_id, meeting_id, approval_id}` or null (AQ-06 §11.6 adds `meeting_id`, AQ-07 §11.4 `approval_id`)."
  def next(nil), do: nil

  def next(n),
    do: %{
      kind: n.kind,
      words: n.words,
      at: n.at,
      task_id: n.task_id,
      meeting_id: Map.get(n, :meeting_id),
      approval_id: Map.get(n, :approval_id)
    }

  @doc """
  The board: `{team, view, pipeline, columns, older_done, empty, lane, lanes}`;
  `lanes` (AQ-04B §9) is null without a lane, else `[{key, name, count, columns}]`.
  """
  def board(b) do
    %{
      team: b.team,
      view: b.view,
      pipeline: b.pipeline && pipeline(b.pipeline),
      columns: Enum.map(b.columns, &column/1),
      older_done: b.older_done,
      empty: b.empty,
      lane: b.lane,
      lanes:
        b.lanes &&
          Enum.map(b.lanes, fn l ->
            %{key: l.key, name: l.name, count: l.count, columns: Enum.map(l.columns, &column/1)}
          end)
    }
  end

  defp column(col) do
    %{
      key: col.key,
      state: col.state,
      stage: stage(col.stage),
      cards: Enum.map(col.cards, &card/1),
      count: col.count
    }
  end

  @doc "The job's panel row."
  def row(r) do
    r
    |> Map.take(@row)
    |> Map.update!(:owner, &person/1)
    |> Map.update!(:stage, &stage/1)
  end

  @doc "The lead's sheet: the card and its facts, its pipeline, its job, *Recent*, `can`."
  def sheet(s) do
    s
    |> card()
    |> Map.merge(Map.take(s, @sheet_facts))
    |> Map.update!(:applied_by, &person/1)
    |> Map.update!(:created_by, &person/1)
    |> Map.update!(:pipeline, &pipeline/1)
    |> Map.update!(:job, &JobsJSON.row/1)
    |> Map.update!(:recent, &Enum.map(&1, fn e -> event(e) end))
    |> Map.update!(:can, &Map.take(&1, @can))
    |> update(:tasks, &Enum.map(&1, fn t -> ApiShared.TasksJSON.card(t) end))
    |> update(:recruiters, &Enum.map(&1, fn r -> ApiShared.ConversationsJSON.recruiter(r) end))
    |> update(:banner, &(&1 && ApiShared.ConversationsJSON.meeting(&1)))
  end

  @doc "A ledger row: `{id, kind, occurred_at, actor: {kind, person?}, from_label, to_label, outcome, note, is_again}`."
  def event(e) do
    %{
      id: e.id,
      kind: e.kind,
      occurred_at: e.occurred_at,
      actor: %{kind: e.actor.kind, person: person(e.actor.person)},
      from_label: e.from_label,
      to_label: e.to_label,
      outcome: e.outcome,
      note: e.note,
      is_again: e.is_again,
      task_id: Map.get(e, :task_id),
      note_id: Map.get(e, :note_id),
      message_id: Map.get(e, :message_id),
      meeting_id: Map.get(e, :meeting_id),
      contact_id: Map.get(e, :contact_id),
      conversation_id: Map.get(e, :conversation_id),
      approval_id: Map.get(e, :approval_id)
    }
  end

  @doc "The check's lead half: `{answer, existing?, same_customer}`."
  def check_half(nil), do: nil

  def check_half(l) do
    %{
      answer: l.answer,
      existing: l.existing && existing(l.existing),
      same_customer: Enum.map(l.same_customer, &existing/1)
    }
  end

  @doc "`details.existing` of a 409, or one of the check's: the keys the caller may know."
  def existing(e) do
    case Map.fetch(e, :by) do
      {:ok, by} -> Map.put(e, :by, person(by))
      :error -> e
    end
  end

  # ── The customer's (§8.4) ───────────────────────────────────────────────────

  @doc "The portal's `GET /leads`: `{todo, in_progress, on_hold, done, older_done}`."
  def customer_list(l) do
    ~w(todo in_progress on_hold done)a
    |> Map.new(&{&1, Enum.map(Map.fetch!(l, &1), fn r -> customer_row(r) end)})
    |> Map.put(:older_done, l.older_done)
  end

  @doc "The customer's lead row."
  def customer_row(r) do
    r
    |> Map.take(~w(id job profile state stage outcome applied_at finished_at last_activity_at)a)
    |> Map.update!(:job, fn job -> Map.update!(job, :money, &Map.take(&1, @money)) end)
  end

  @doc "The customer's lead sheet: §8.4's fields, the customer-visible events, `can: {applied}`."
  def customer_sheet(s) do
    s
    |> Map.take(
      ~w(id job profile state stage progress outcome applied_at applied_via cv cover_letter_md
         bid expectation finished_at last_activity_at events can tasks conversations)a
    )
    |> Map.update!(:job, fn job -> Map.update!(job, :money, &Map.take(&1, @money)) end)
    |> Map.update!(:events, &Enum.map(&1, fn e -> customer_event(e) end))
    |> Map.update!(:can, &Map.take(&1, [:applied]))
    |> update(:tasks, &Enum.map(&1, fn t -> ApiShared.TasksJSON.portal_card(t) end))
    |> update(
      :conversations,
      &(&1 && Enum.map(&1, fn c -> ApiShared.ConversationsJSON.conversation(c) end))
    )
  end

  defp customer_event(e) do
    %{
      id: e.id,
      kind: e.kind,
      occurred_at: e.occurred_at,
      actor: %{kind: e.actor.kind, person: person(e.actor.person)},
      from_label: e.from_label,
      to_label: e.to_label,
      outcome: e.outcome,
      is_again: e.is_again
    }
  end

  @doc "`GET /suggestions`: `[{job, profile, score}]`."
  def suggestions(list) do
    Enum.map(list, fn s ->
      %{
        job: Map.update!(s.job, :money, &Map.take(&1, @money)),
        profile: s.profile,
        score: s.score
      }
    end)
  end

  # ── AQ-04B §8.4 ─────────────────────────────────────────────────────────────

  @tracker_row ~w(id applied_at title company source customer profile owner state stage outcome next
                  last_activity_at quiet money workplace engagement cv labels missing)a

  @doc "`GET /leads/:id/history`: `{items: [event], next_cursor}`."
  def history(page),
    do: %{items: Enum.map(page.items, &event/1), next_cursor: page.next_cursor}

  @doc "A note: `{id, body_md, author, inserted_at, updated_at, can: {edit, delete}}`."
  def note(n) do
    %{
      id: n.id,
      body_md: n.body_md,
      author: person(n.author),
      inserted_at: n.inserted_at,
      updated_at: n.updated_at,
      can: Map.take(n.can, [:edit, :delete])
    }
  end

  @doc "A label: `{id, name, lead_count}`."
  def label(l), do: Map.take(l, [:id, :name, :lead_count])

  @doc "A saved view: `{id, screen, name, query, columns, position}`."
  def saved_view(v), do: Map.take(v, [:id, :screen, :name, :query, :columns, :position])

  @doc """
  `GET /tracker`: `{items: [tracker row], next_cursor, total, groups}` —
  `groups` (`[{key, name, count}]` over every matching row) only when
  grouped, else null.
  """
  def tracker(page) do
    %{
      items: Enum.map(page.items, &tracker_row/1),
      next_cursor: page.next_cursor,
      total: page.total,
      groups: page.groups
    }
  end

  @doc "A Tracker row (§8.4)."
  def tracker_row(r) do
    r
    |> Map.take(@tracker_row)
    |> Map.update!(:stage, &stage/1)
    |> Map.update!(:owner, &person/1)
    |> Map.update!(:next, &next/1)
    |> Map.update!(:quiet, &Map.take(&1, [:archives_on, :days_left, :warn]))
    |> Map.update!(:money, &Map.take(&1, @money))
  end

  @doc "`POST /leads/bulk`: `{done: [id], refused: [{id, code, message}]}`."
  def bulk(r),
    do: %{done: r.done, refused: Enum.map(r.refused, &Map.take(&1, [:id, :code, :message]))}

  @doc """
  `GET /retention/preview` (§8.4): `{archives: [{lead, quiet_since, on}],
  purges: [{lead, archived_at, on}], jobs: [{job, quiet_since, archives_on,
  purges_on}]}`, `lead` a lead row, `job` P3's job row.
  """
  def preview(p) do
    %{
      archives:
        Enum.map(
          p.archives,
          &%{lead: preview_lead(&1.lead), quiet_since: &1.quiet_since, on: &1.on}
        ),
      purges:
        Enum.map(
          p.purges,
          &%{lead: preview_lead(&1.lead), archived_at: &1.archived_at, on: &1.on}
        ),
      jobs:
        Enum.map(
          p.jobs,
          &%{
            job: JobsJSON.row(&1.job),
            quiet_since: &1.quiet_since,
            archives_on: &1.archives_on,
            purges_on: &1.purges_on
          }
        )
    }
  end

  # A lead row, with the job it is on, so Settings › Retention can name it.
  defp preview_lead(l), do: l |> row() |> Map.put(:job, l.job) |> Map.put(:team, l.team)

  defp person(nil), do: nil
  defp person(p), do: Map.take(p, @person)
end
