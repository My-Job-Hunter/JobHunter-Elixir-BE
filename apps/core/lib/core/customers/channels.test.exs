defmodule Core.Customers.ChannelsTest do
  @moduledoc """
  AQ-09 §4, §6.1 and §11.4 on the channel: an email channel's token from
  birth, its `forwarding` for whoever sees it, *New address* (the old
  address dead at once) by the customer's leads, the served profiles'
  owners, the system admin and the customer, and refused to everyone else;
  a channel that isn't email has neither.
  """

  use Core.CoreCase, async: true

  alias Core.Customers.Channels
  alias Core.Inbound
  alias Data.Scope

  @now ~U[2026-11-12 09:00:00.000000Z]

  setup do
    c = board_cast_fixture()

    {:ok, channel} =
      Channels.create(
        scope_for(c.hira),
        c.tanweer.id,
        %{"kind" => "email", "handle" => "tanweer@example.com"},
        @now
      )

    :ok = Data.Profiles.put_channels(c.golang, [channel.id])
    Map.put(c, :channel, channel)
  end

  test "made with its token; the address from config; forwarding for staff and the customer, nothing for other kinds",
       c do
    assert c.channel.inbound_token =~ ~r/^[a-z2-9]{10}$/

    assert c.channel.forwarding == %{
             address: "in+#{c.channel.inbound_token}@inbound.autoqare.local",
             last_inbound_at: nil,
             confirmation: nil,
             can_renew: true
           }

    {:ok, [mine]} = Channels.list(customer_scope_for(c.tanweer), c.tanweer.id)
    assert mine.forwarding.address == Inbound.address(c.channel.inbound_token)
    assert mine.forwarding.can_renew

    {:ok, other} =
      Channels.create(
        scope_for(c.hira),
        c.tanweer.id,
        %{"kind" => "linkedin", "handle" => "https://linkedin.com/in/t"},
        @now
      )

    assert other.inbound_token == nil and other.forwarding == nil
    assert Channels.get(customer_scope_for(c.naveed), c.channel.id) == {:error, :not_found}
  end

  test "a kind changed away from email drops the token; back to email makes a new one", c do
    {:ok, linkedin} = Channels.update(scope_for(c.hira), c.channel.id, %{"kind" => "other"})
    assert linkedin.inbound_token == nil and linkedin.forwarding == nil
    {:ok, email} = Channels.update(scope_for(c.hira), c.channel.id, %{"kind" => "email"})
    assert email.inbound_token not in [nil, c.channel.inbound_token]
  end

  test "New address: a fresh token, the old address unknown at once", c do
    old = Inbound.address(c.channel.inbound_token)
    assert {:ok, renewed} = Channels.renew_address(scope_for(c.fiza), c.channel.id, @now)
    assert renewed.inbound_token != c.channel.inbound_token
    assert renewed.forwarding.address == Inbound.address(renewed.inbound_token)

    mail = File.read!(Path.expand("../../../priv/eml/thread-1.eml", __DIR__))

    assert {:ok, %{outcome: :unknown_address}} =
             Inbound.dev(Scope.system(), %{"to" => old, "eml" => mail}, @now)

    assert {:ok, %{outcome: :landed}} =
             Inbound.dev(
               Scope.system(),
               %{"to" => renewed.forwarding.address, "eml" => mail},
               @now
             )

    assert [%{action: "address_renewed"}] =
             Repo.all(Data.Audit.AuditEvent) |> Enum.filter(&(&1.action == "address_renewed"))
  end

  test "who may make a new address (§4)", c do
    stranger = user_fixture()

    for {who, scope, expected} <- [
          {:dawud, scope_for(c.dawud), :ok},
          {:hira, scope_for(c.hira), :ok},
          {:bilal, scope_for(c.bilal), :ok},
          {:fiza, scope_for(c.fiza), :ok},
          {:qasim, scope_for(c.qasim), :ok},
          {:muaz, scope_for(c.muaz),
           {:error, {:forbidden, "Only the customer's leads and owners can change it."}}},
          {:tanweer, customer_scope_for(c.tanweer), :ok},
          {:naveed, customer_scope_for(c.naveed), {:error, :not_found}},
          {:stranger, scope_for(stranger), {:error, :not_found}}
        ] do
      got =
        case Channels.renew_address(scope, c.channel.id, @now) do
          {:ok, _channel} -> :ok
          error -> error
        end

      assert got == expected, "#{who}: #{inspect(got)}"
    end

    # `can_renew` says the same.
    {:ok, seen} = Channels.get(scope_for(c.muaz), c.channel.id)
    refute seen.forwarding.can_renew
  end

  test "422 on a channel that isn't email", c do
    {:ok, linkedin} =
      Channels.create(
        scope_for(c.hira),
        c.tanweer.id,
        %{"kind" => "linkedin", "handle" => "https://linkedin.com/in/t"},
        @now
      )

    assert Channels.renew_address(scope_for(c.hira), linkedin.id, @now) ==
             {:error,
              {:invalid, %{"kind" => ["Only an email channel has a forwarding address."]}}}
  end
end
