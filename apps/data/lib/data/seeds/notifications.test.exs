defmodule Data.Seeds.NotificationsTest do
  use Data.DataCase, async: true

  alias Data.Notifications
  alias Data.Notifications.Kind
  alias Data.Seeds.Notifications, as: Seed

  doctest Seed

  test "the six groups, Account last, and their thirty kinds, each with in-app; a second load changes nothing" do
    _first = Seed.load()
    assert Seed.load() == %{inserted: 0, updated: 0, kept: 36}

    assert [
             %{key: "tasks", label: "Tasks"},
             %{key: "leads", label: "Leads"},
             %{key: "conversations", label: "Conversations"},
             %{key: "meetings", label: "Meetings"},
             %{key: "approvals", label: "Approvals"},
             %{key: "account", label: "Account", can_disable: false}
           ] = Notifications.groups()

    kinds = Map.new(Notifications.kinds(), &{&1.key, &1})
    assert map_size(kinds) == 30
    assert Enum.all?(kinds, fn {_key, k} -> "inapp" in k.default_channels end)

    # AQ-08 §6's corrections and additions (the whole matrix is
    # `Core.Notifications.ChannelsTest`'s).
    assert kinds["leads.follow_up_due"].default_channels == ~w(inapp digest)
    assert kinds["conversations.reply_received"].default_channels == ~w(inapp push extension)
    assert kinds["meetings.scheduled"].default_channels == ~w(inapp push email)
    assert kinds["approvals.overdue"].default_channels == ~w(inapp push email)
    assert kinds["leads.customer_milestone"].default_channels == ~w(inapp push email)
    assert kinds["meetings.day_before"].default_channels == ~w(inapp push email)
    assert kinds["account.digest"].default_channels == ~w(inapp email)
    assert kinds["account.push_test"].default_channels == ~w(inapp push)

    passing = for {key, %{can_ignore_quiet_hours: true}} <- kinds, do: key
    assert Enum.sort(passing) == ~w(account.digest account.push_test meetings.reminder)
  end

  test "a kind seeded before a change is updated in place; a person's own rows stay" do
    _first = Seed.load()

    Repo.get!(Kind, "meetings.reminder")
    |> Ecto.Changeset.change(default_channels: ["inapp"], can_ignore_quiet_hours: false)
    |> Repo.update!()

    Repo.get!(Data.Notifications.Group, "account")
    |> Ecto.Changeset.change(can_disable: true)
    |> Repo.update!()

    assert Seed.load() == %{inserted: 0, updated: 2, kept: 34}

    assert %{default_channels: ~w(inapp push), can_ignore_quiet_hours: true} =
             Repo.get!(Kind, "meetings.reminder")

    refute Repo.get!(Data.Notifications.Group, "account").can_disable
  end

  test "every kind has a label for delivery health" do
    for {key, _channels} <- Seed.kinds(), do: refute(Seed.label(key) == key)
    assert Seed.label("meetings.day_before") == "Meeting tomorrow"
    assert Seed.label("leads.customer_milestone") == "Your search moved forward"
    assert Seed.label("unknown.kind") == "unknown.kind"
  end
end
