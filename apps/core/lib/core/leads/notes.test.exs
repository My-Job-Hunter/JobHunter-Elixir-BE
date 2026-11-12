defmodule Core.Leads.NotesTest do
  @moduledoc """
  AQ-04B §4, QP4b-13: notes are staff only; whoever may change the lead adds
  one (a `note_added` in History, activity); its author or a team lead
  edits or deletes it (audited, no event); a member at `view` is refused in
  words; the customer finds nothing.
  """

  use Core.CoreCase, async: true

  alias Core.Leads.{Notes, Sheet}
  alias Data.Leads, as: Store

  @now ~U[2026-11-11 09:00:00.000000Z]

  setup do
    c = board_cast_fixture()
    lead = lead_fixture(scope_for(c.fiza), team: c.backend, profile: c.golang, as: :apply)
    Map.put(c, :lead, lead)
  end

  defp level(c, level), do: {:ok, _} = Data.Teams.put_settings(c.backend.id, %{peer_leads: level})

  test "Fiza adds a note: it lists newest first, and History has note_added with its body", c do
    body = "Spoke to the recruiter; they want a portfolio link."

    assert {:ok, %{body_md: ^body, author: %{name: "Fiza"}, can: %{edit: true, delete: true}}} =
             Notes.add(scope_for(c.fiza), c.lead.id, %{"body_md" => "  #{body}  "}, @now)

    assert {:ok, [note]} = Notes.list(scope_for(c.hira), c.lead.id)
    assert note.body_md == body

    [event | _] = Store.events(c.lead.id)
    assert event.kind == :note_added and event.visibility == :staff
    assert Sheet.event(event).note == body
    assert Store.reload(c.lead).last_activity_at == @now
  end

  test "Qasim's edit of Fiza's note is refused; Hira's is allowed and audited", c do
    level(c, :edit)
    {:ok, note} = Notes.add(scope_for(c.fiza), c.lead.id, %{"body_md" => "First"}, @now)

    assert Notes.edit(scope_for(c.qasim), note.id, %{"body_md" => "Mine"}, @now) ==
             {:error, {:forbidden, "Only its author or a team lead can change a note."}}

    assert {:ok, %{body_md: "Hira's"}} =
             Notes.edit(scope_for(c.hira), note.id, %{"body_md" => "Hira's"}, @now)

    assert [_created, %{action: "updated"}] =
             Data.Audit.list_for_subject(c.org.id, "lead_notes", note.id)

    assert Notes.delete(scope_for(c.qasim), note.id, @now) ==
             {:error, {:forbidden, "Only its author or a team lead can change a note."}}

    assert Notes.delete(scope_for(c.fiza), note.id, @now) == :ok
    assert {:ok, []} = Notes.list(scope_for(c.fiza), c.lead.id)

    # The ledger row stays, unlinked: History says a note was added.
    [event | _] = Store.events(c.lead.id)
    assert event.kind == :note_added and event.note_id == nil
  end

  test "who adds: at view a member is refused in words; at hidden not found; edit allowed", c do
    level(c, :view)

    assert Notes.add(scope_for(c.muaz), c.lead.id, %{"body_md" => "x"}, @now) ==
             {:error, {:forbidden, "Only the people working this lead can add a note."}}

    level(c, :hidden)

    assert Notes.add(scope_for(c.muaz), c.lead.id, %{"body_md" => "x"}, @now) ==
             {:error, :not_found}

    assert Notes.list(scope_for(c.muaz), c.lead.id) == {:error, :not_found}

    level(c, :edit)

    assert {:ok, %{can: %{edit: true}}} =
             Notes.add(scope_for(c.muaz), c.lead.id, %{"body_md" => "x"}, @now)
  end

  test "the customer finds no note, and no route to one", c do
    {:ok, note} = Notes.add(scope_for(c.fiza), c.lead.id, %{"body_md" => "Ours"}, @now)
    tanweer = customer_scope_for(c.tanweer)

    assert Notes.list(tanweer, c.lead.id) == {:error, :not_found}
    assert Notes.add(tanweer, c.lead.id, %{"body_md" => "x"}, @now) == {:error, :not_found}
    assert Notes.edit(tanweer, note.id, %{"body_md" => "x"}, @now) == {:error, :not_found}

    {:ok, sheet} = Core.Leads.get(tanweer, c.lead.id, @now)
    refute Enum.any?(sheet.events, &(&1.kind == :note_added))
  end

  test "an empty note is a field error; the sheet counts the notes", c do
    assert Notes.add(scope_for(c.fiza), c.lead.id, %{"body_md" => "  "}, @now) ==
             {:error, {:missing, [:body_md]}}

    _ = note_fixture(scope_for(c.fiza), c.lead)
    assert {:ok, %{notes_count: 1}} = Core.Leads.get(scope_for(c.fiza), c.lead.id, @now)
  end
end
