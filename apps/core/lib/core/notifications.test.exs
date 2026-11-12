defmodule Core.NotificationsTest do
  @moduledoc "The bell (AQ-02 §7.1): each person their own — page, count, groups, read, read all."

  use Core.CoreCase, async: true

  alias Core.Notifications

  @now ~U[2026-11-10 09:00:00.000000Z]

  setup do
    org = organisation_fixture()
    hira = admin_fixture(org, display_name: "Hira Khan")
    fiza = user_fixture(display_name: "Fiza")
    %{org: org, hira: hira, fiza: fiza, scope: scope_for(fiza, organisation: org)}
  end

  test "a page of the person's own, by cursor, in §7.6's shape", %{
    org: org,
    fiza: fiza,
    hira: hira,
    scope: scope
  } do
    for n <- 1..3,
        do:
          notification_fixture(org, fiza,
            dedupe_key: "k#{n}",
            actor_user_id: hira.id,
            link_path: "/board/x"
          )

    notification_fixture(org, hira)

    assert {:ok, %{items: [first, _second], next_cursor: cursor}} =
             Notifications.page(scope, %{"limit" => "2"})

    assert is_binary(cursor)

    assert %{
             kind: "tasks.assigned",
             group: "tasks",
             actor: %{name: "Hira Khan", photo_url: nil},
             read_at: nil
           } = first

    assert Map.keys(first) |> Enum.sort() ==
             ~w(actor approval_id body group id inserted_at kind lead_id link_path read_at task_id
                title)a

    assert {:ok, %{items: [_third], next_cursor: nil}} =
             Notifications.page(scope, %{"limit" => "2", "cursor" => cursor})

    assert {:error, {:invalid, %{"cursor" => _}}} =
             Notifications.page(scope, %{"cursor" => "nonsense"})

    assert {:ok, %{unread: 3}} = Notifications.count(scope)
    assert {:ok, [%{key: "tasks", label: "Tasks"}]} = Notifications.groups(scope)
  end

  test "read one's own, never another's; read all", %{
    org: org,
    fiza: fiza,
    hira: hira,
    scope: scope
  } do
    mine = notification_fixture(org, fiza)
    notification_fixture(org, fiza)
    theirs = notification_fixture(org, hira)

    assert Notifications.read(scope, theirs.id, @now) == {:error, :not_found}
    assert Notifications.read(scope, "not-an-id", @now) == {:error, :not_found}
    assert Notifications.read(scope, mine.id, @now) == :ok
    assert {:ok, %{unread: 1}} = Notifications.count(scope)
    assert Notifications.read_all(scope, @now) == :ok
    assert {:ok, %{unread: 0}} = Notifications.count(scope)
    assert {:ok, %{unread: 1}} = Notifications.count(scope_for(hira))

    assert {:ok, %{items: [], next_cursor: nil}} =
             Notifications.page(scope, %{"unread" => "true"})
  end

  # AQ-08 QP8-1: one seam, so no notice module can forget its deliveries.
  test "no module but Core.Notifications writes a notification through Data.Notifications.ensure" do
    root = Path.expand("..", __DIR__)

    offenders =
      for path <- Path.wildcard(Path.join(root, "**/*.ex")),
          Path.basename(path) != "notifications.ex" or
            Path.dirname(path) != Path.join(root, "core"),
          source = File.read!(path),
          source =~ "Data.Notifications.ensure(" or
            (source =~ ~r/^  alias Data\.Notifications$/m and source =~ "Notifications.ensure("),
          do: Path.relative_to(path, root)

    assert offenders == [], "write through Core.Notifications.ensure/2: #{inspect(offenders)}"
  end
end
