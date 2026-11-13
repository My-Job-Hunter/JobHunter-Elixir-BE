defmodule Core.Notifications.SettingsTest do
  @moduledoc """
  Notifications › Settings and push on a browser (AQ-08 §8, §11.4): each
  person their own; a switch per group and channel the group uses, none for
  the extension for a customer; Account can't be turned off; a browser
  turned on in the surface's app, moved when another person signs in
  there; *Send a test* through the pipeline.
  """

  use Core.CoreCase, async: true

  alias Core.Notifications.{Push, Settings}
  alias Data.Notifications.Deliveries

  @now ~U[2026-11-12 06:00:00.000000Z]

  setup do
    org = organisation_fixture()
    team = team_fixture(org)
    fiza = member_fixture(team, :member, user_fixture(display_name: "Fiza"))
    customer = customer_fixture(org, [team], login: true)
    tanweer = Data.Accounts.get_user(customer.user_id)
    %{fiza: fiza, fiza_scope: scope_for(fiza), tanweer: tanweer, customer: customer}
  end

  test "the settings: every group in order, Account last; uses within push · email · extension · digest; all on",
       c do
    assert {:ok, settings} = Settings.get(c.fiza_scope, :team)

    assert Enum.map(settings.groups, & &1.key) ==
             ~w(tasks leads conversations meetings approvals account)

    uses = Map.new(settings.groups, &{&1.key, &1.uses})
    assert uses["tasks"] == ~w(push digest)
    assert uses["leads"] == ~w(push email digest)
    assert uses["conversations"] == ~w(push email extension digest)
    assert uses["meetings"] == ~w(push email)
    assert uses["approvals"] == ~w(push email)
    assert uses["account"] == ~w(push email)

    assert Enum.all?(settings.groups, &(&1.push and &1.email and &1.extension and &1.digest))
    assert %{key: "account", label: "Account", can_disable: false} = List.last(settings.groups)

    assert settings.quiet_hours == %{from: nil, to: nil}
    assert settings.digest == %{on: true, at: "08:00"}
    assert settings.zone == "Asia/Karachi"
    assert settings.has == %{push: false, extension: false}

    push_subscription_fixture(c.fiza, app: :team)
    device_fixture(c.fiza_scope)
    assert {:ok, %{has: %{push: true, extension: true}}} = Settings.get(c.fiza_scope, :team)
    assert {:ok, %{has: %{push: false}}} = Settings.get(c.fiza_scope, :client)
  end

  test "a customer has no extension column and never has the extension", c do
    scope = customer_scope_for(c.customer)
    assert {:ok, settings} = Settings.get(scope, :client)

    refute Enum.any?(settings.groups, &("extension" in &1.uses))
    assert settings.has.extension == false
  end

  test "a switch turned off and on again; another person's are untouched", c do
    assert {:ok, settings} =
             Settings.put_group(c.fiza_scope, "approvals", %{"email" => false}, :team, @now)

    approvals = Enum.find(settings.groups, &(&1.key == "approvals"))
    assert approvals.email == false and approvals.push == true

    {:ok, settings} =
      Settings.put_group(c.fiza_scope, "approvals", %{"email" => true}, :team, @now)

    assert Enum.find(settings.groups, &(&1.key == "approvals")).email

    {:ok, mine} = Settings.put_group(c.fiza_scope, "tasks", %{push: false}, :team, @now)
    refute Enum.find(mine.groups, &(&1.key == "tasks")).push

    {:ok, theirs} = Settings.get(customer_scope_for(c.customer), :client)
    assert Enum.find(theirs.groups, &(&1.key == "tasks")).push
  end

  test "the refusals: an unknown group, Account, a channel the group doesn't use, the extension for a customer",
       c do
    assert Settings.put_group(c.fiza_scope, "nope", %{"push" => false}, :team, @now) ==
             {:error, :not_found}

    assert Settings.put_group(c.fiza_scope, "account", %{"email" => false}, :team, @now) ==
             {:error, {:invalid, %{"group" => ["These can't be turned off."]}}}

    assert Settings.put_group(c.fiza_scope, "tasks", %{"email" => false}, :team, @now) ==
             {:error, {:invalid, %{"email" => ["This group doesn't use it."]}}}

    assert Settings.put_group(c.fiza_scope, "tasks", %{"push" => "off"}, :team, @now) ==
             {:error, {:invalid, %{"push" => ["must be true or false"]}}}

    assert Settings.put_group(
             customer_scope_for(c.customer),
             "conversations",
             %{"extension" => false},
             :client,
             @now
           ) == {:error, {:invalid, %{"extension" => ["The extension is for the team."]}}}
  end

  describe "push on a browser" do
    @keys %{"p256dh" => "BPkey", "auth" => "authsecret"}

    test "turned on in the surface's app, newest first; a known endpoint moves; removed by endpoint",
         c do
      {:ok, page} =
        Push.subscribe(
          c.fiza_scope,
          :team,
          %{"endpoint" => "https://fcm.example/a", "keys" => @keys, "app" => "client"},
          @now
        )

      assert [%{app: :team, endpoint: "https://fcm.example/a", inserted_at: _}] = page.devices
      assert page.public_key =~ ~r/^B/

      # The same browser, signed in as the customer on the portal: it moves to them.
      tanweer = customer_scope_for(c.customer)

      {:ok, theirs} =
        Push.subscribe(
          tanweer,
          :client,
          %{"endpoint" => "https://fcm.example/a", "keys" => @keys},
          @now
        )

      assert [%{app: :client}] = theirs.devices
      assert {:ok, %{devices: []}} = Push.page(c.fiza_scope)

      # Removing another's endpoint is no error and removes nothing.
      assert {:ok, %{devices: []}} =
               Push.remove(c.fiza_scope, %{"endpoint" => "https://fcm.example/a"})

      assert {:ok, %{devices: [_still]}} = Push.page(tanweer)

      assert {:ok, %{devices: []}} =
               Push.remove(tanweer, %{"endpoint" => "https://fcm.example/a"})
    end

    test "422 on endpoint for a missing key or an endpoint not https://", c do
      lost =
        {:error,
         {:invalid, %{"endpoint" => ["This browser's subscription didn't come through."]}}}

      assert Push.subscribe(
               c.fiza_scope,
               :team,
               %{"endpoint" => "http://x.example/a", "keys" => @keys},
               @now
             ) == lost

      assert Push.subscribe(
               c.fiza_scope,
               :team,
               %{"endpoint" => "https://x.example/a", "keys" => %{"auth" => "a"}},
               @now
             ) == lost

      assert Push.subscribe(c.fiza_scope, :team, %{"keys" => @keys}, @now) == lost
    end

    test "Send a test: account.push_test through the pipeline, each press its own", c do
      push_subscription_fixture(c.fiza)

      assert :ok = Push.test(c.fiza_scope, @now)
      assert :ok = Push.test(c.fiza_scope, DateTime.add(@now, 1, :second))

      tests =
        for n <- Repo.all(Data.Notifications.Notification),
            n.notification_kind_key == "account.push_test",
            do: n

      assert [
               %{
                 title: "Push works. AutoQare can reach this browser.",
                 link_path: "/notifications"
               } = n,
               _two
             ] = tests

      assert n.dedupe_key =~ "push_test:#{c.fiza.id}:"
      assert [%{channel: :push, deliver_after: _}] = Deliveries.for_notification(n.id)
    end
  end
end
