defmodule ApiShared.TasksJSON do
  @moduledoc """
  The board's shapes (AQ-02 §7.6), for both apps: the card, the step card,
  the board page, the sheet, the thread, the history, the stages — and the
  portal's card, sheet and board, separate functions that list the
  customer's fields only. `Core.Tasks.Cards` builds what they show (it
  depends on who reads); this module lists every field by name, so a field
  somebody adds to the read model never reaches the wire unasked.

  No map is keyed by data except `counts.by_state` (§7.6): columns are a
  list.
  """

  import Plug.Conn, only: [send_resp: 3]
  import Phoenix.Controller, only: [json: 2]

  @person ~w(user_id name photo_url is_customer)a
  @card ~w(kind id title state stage priority due_at due_on overdue team customer profile
           customer_access source people needs_owner progress comment_count file_count hold
           closed done_at mine can_move updated_at)a
  @sheet ~w(description reminder_minutes author inserted_at held_from_state checklist steps links
            relations files watchers me_on can customer_sees)a
  @portal_card ~w(id title state due_at due_on overdue profile source customer_access people on_it
                  progress comment_count file_count done_at closed yours_to_do made_by_you
                  updated_at)a
  @portal_sheet ~w(description checklist steps links files can)a
  @comment ~w(id author body is_staff_only edited_at deleted inserted_at mine)a

  # ── The console ─────────────────────────────────────────────────────────────

  @doc ~s(A card, `kind: "task"`, or a step card, `kind: "step"`.)
  def item(%{kind: "step"} = c), do: %{kind: "step", step: c.step, task: card(c.task)}
  def item(card), do: card(card)

  @doc "The console's card."
  def card(c),
    do:
      c
      |> Map.take(@card)
      |> Map.update!(:people, &Enum.map(&1, fn p -> person(p, [:level, :me]) end))

  @doc "`GET /board`."
  def board(page) do
    %{
      counts: page.counts,
      columns:
        Enum.map(
          page.columns,
          &%{state: &1.state, items: Enum.map(&1.items, fn i -> item(i) end)}
        ),
      in_progress_groups:
        Enum.map(page.in_progress_groups, fn g ->
          %{
            key: g.key,
            label: g.label,
            stage: g.stage,
            person: person(g.person),
            items: Enum.map(g.items, &item/1)
          }
        end),
      stages: page.stages,
      people: Enum.map(page.people, &person/1),
      team: page.team,
      teams: page.teams,
      empty: page.empty
    }
  end

  @doc "The console's sheet: the card and its parts."
  def sheet(s) do
    s
    |> Map.take(@sheet)
    |> Map.merge(card(s))
    |> Map.update!(:author, &person/1)
    |> Map.update!(:watchers, &Enum.map(&1, fn p -> person(p) end))
    |> Map.update!(
      :checklist,
      &Enum.map(&1, fn i -> Map.update!(i, :checked_by, fn p -> person(p) end) end)
    )
    |> Map.update!(:steps, fn steps ->
      Enum.map(
        steps,
        &(&1
          |> Map.update!(:assignee, fn p -> person(p) end)
          |> Map.update!(:done_by, fn p -> person(p) end))
      )
    end)
    |> Map.update!(
      :files,
      &Enum.map(&1, fn f -> Map.update!(f, :added_by, fn p -> person(p) end) end)
    )
  end

  @doc "Answers the console's sheet, or 204 when the write took the task out of the caller's sight."
  def send_sheet(conn, :gone), do: send_resp(conn, 204, "")
  def send_sheet(conn, sheet), do: json(conn, sheet(sheet))

  @doc "`GET /tasks/:id/comments`: comments with their replies."
  def thread(comments) do
    Enum.map(comments, fn c ->
      c |> comment() |> Map.put(:replies, Enum.map(c.replies, &comment/1))
    end)
  end

  defp comment(c), do: c |> Map.take(@comment) |> Map.update!(:author, &person/1)

  @doc "`GET /tasks/:id/history`: change groups, newest first."
  def history(groups) do
    Enum.map(groups, fn g ->
      %{
        change_group_id: g.change_group_id,
        actor: person(g.actor),
        changed_at: g.changed_at,
        lines: Enum.map(g.lines, &Map.take(&1, [:field, :from_label, :to_label]))
      }
    end)
  end

  @doc "`/me/stages`: `{stages: [{id, name, position, in_use}], suggested}`."
  def stages(%{stages: stages, suggested: suggested}) do
    %{
      stages:
        Enum.map(stages, &%{id: &1.id, name: &1.name, position: &1.position, in_use: &1.in_use}),
      suggested: suggested
    }
  end

  # ── The portal ──────────────────────────────────────────────────────────────

  @doc "The portal's card: no team, stage, priority or hold reason."
  def portal_card(c), do: Map.take(c, @portal_card)

  @doc "`GET /client/v1/board`."
  def portal_board(board) do
    %{
      waiting_on_you: Enum.map(board.waiting_on_you, &portal_card/1),
      with_team: Enum.map(board.with_team, &portal_card/1),
      done: Enum.map(board.done, &portal_card/1),
      older_done: board.older_done,
      empty: board.empty
    }
  end

  @doc "The portal's sheet."
  def portal_sheet(s), do: s |> Map.take(@portal_sheet) |> Map.merge(portal_card(s))

  @doc "Answers the portal's sheet, or 204 when the task left the customer's sight."
  def send_portal_sheet(conn, :gone), do: send_resp(conn, 204, "")
  def send_portal_sheet(conn, sheet), do: json(conn, portal_sheet(sheet))

  # A person: `{user_id, name, photo_url}`, `is_customer` only when true.
  defp person(nil), do: nil
  defp person(p, extra \\ []), do: Map.take(p, @person ++ extra)
end
