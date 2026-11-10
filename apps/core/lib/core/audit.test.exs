defmodule Core.AuditTest do
  use Core.CoreCase, async: true

  alias Core.Audit
  alias Data.Audit, as: Rows

  test "a row names the actor, how, what, on what, and when" do
    org = organisation_fixture()
    admin = admin_fixture(org)
    scope = scope_for(admin, request_id: "req-9")
    team = team_fixture(org)
    now = ~U[2026-11-09 10:00:00.000000Z]

    {:ok, event} =
      Audit.record(scope, "updated", team,
        before: %{name: "Old"},
        after: %{name: team.name},
        now: now
      )

    assert event.organisation_id == org.id
    assert event.actor_user_id == admin.id
    assert event.via == :web
    assert event.subject_kind == "teams"
    assert event.subject_id == team.id
    assert event.action == "updated"
    assert event.before == %{"name" => "Old"}
    assert event.after == %{"name" => team.name}
    assert event.request_id == "req-9"
    assert event.occurred_at == now
    assert [^event] = Rows.list_for_subject(org.id, "teams", team.id)
  end

  test "a 1:1 settings row is keyed by its own primary key" do
    org = organisation_fixture()
    scope = Data.Scope.system(org)
    settings = Data.Organisations.get_settings(org.id)

    {:ok, event} = Audit.record(scope, "updated", settings)

    assert event.subject_kind == "organisation_settings"
    assert event.subject_id == org.id
    assert event.actor_user_id == nil
    assert event.via == :system
  end

  test "a rolled-back write leaves no row" do
    org = organisation_fixture()
    scope = Data.Scope.system(org)
    team = team_fixture(org)

    Repo.transaction(fn ->
      {:ok, _event} = Audit.record(scope, "updated", team)
      Repo.rollback(:nope)
    end)

    assert Rows.list_for_subject(org.id, "teams", team.id) == []
  end

  test "snapshot turns a struct's fields into JSON-safe values" do
    at = ~U[2026-11-09 10:00:00.000000Z]

    assert Audit.snapshot(%{role: :lead, joined_at: at, name: "x", on: true}, [
             :role,
             :joined_at,
             :name,
             :on
           ]) ==
             %{
               "role" => "lead",
               "joined_at" => "2026-11-09T10:00:00.000000Z",
               "name" => "x",
               "on" => true
             }

    assert Audit.snapshot(nil, [:role]) == nil
  end
end
