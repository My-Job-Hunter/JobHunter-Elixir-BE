defmodule Core.ExtensionTest do
  @moduledoc """
  AQ-05 §7 (P5.1): a code works once, for two minutes; tokens stay in their
  own app; *Disconnect* kills the refresh. Every connect and disconnect is
  audited.
  """

  use Core.CoreCase, async: true

  import Ecto.Query, only: [from: 2]

  alias Core.Accounts
  alias Core.Auth.Guardian
  alias Core.Extension
  alias Data.Audit.AuditEvent

  @now ~U[2026-11-11 09:00:00.000000Z]
  @agent "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 Chrome/130.0 Safari/537.36"
  @client %{agent: @agent, ip: "127.0.0.1", request_id: "req-ext"}

  setup do
    c = board_cast_fixture()
    Map.merge(c, %{s_fiza: scope_for(c.fiza), s_dawud: scope_for(c.dawud)})
  end

  defp connect(scope, at \\ @now) do
    {:ok, %{code: code}} = Extension.connect_code(scope, at)
    Extension.connect(code, %{"extension_version" => "0.1.0"}, @client, at)
  end

  describe "the connect code" do
    test "any staff member mints one: 32 URL-safe characters, two minutes", c do
      assert {:ok, %{code: code, expires_at: expires_at}} = Extension.connect_code(c.s_fiza, @now)
      assert code =~ ~r/^[A-Za-z0-9_-]{32}$/
      assert expires_at == DateTime.add(@now, 120, :second)

      # Only its digest is kept.
      refute Repo.exists?(from(t in Data.Accounts.UserToken, where: t.token_digest == ^code))
    end

    test "a customer cannot connect", c do
      assert Extension.connect_code(customer_scope_for(c.tanweer), @now) == {:error, :not_found}
    end
  end

  describe "connecting" do
    test "the code becomes a device and its own pair, sid the device, app ext", c do
      assert {:ok, %{device: device, tokens: tokens, scope: scope}} = connect(c.s_fiza)

      assert device.user_id == c.fiza.id
      assert device.name == "Chrome on macOS"
      assert device.extension_version == "0.1.0"
      assert device.connected_at == @now and device.last_seen_at == @now
      assert scope.via == :extension

      {:ok, claims} = Guardian.decode_and_verify(tokens.access_token)
      assert claims["sid"] == device.id
      assert claims["dev"]["app"] == "ext"
      assert Guardian.extension_token?(claims)

      assert [%{via: :extension, actor_user_id: actor}] =
               Repo.all(
                 from(e in AuditEvent,
                   where: e.subject_id == ^device.id and e.action == "connected"
                 )
               )

      assert actor == c.fiza.id
    end

    test "a code works once: the second exchange is token_invalid", c do
      {:ok, %{code: code}} = Extension.connect_code(c.s_fiza, @now)

      assert {:ok, _first} =
               Extension.connect(code, %{"extension_version" => "0.1.0"}, @client, @now)

      assert Extension.connect(code, %{"extension_version" => "0.1.0"}, @client, @now) ==
               {:error, :token_invalid}
    end

    test "an expired code, an unknown one and none at all are token_invalid", c do
      {:ok, %{code: code}} = Extension.connect_code(c.s_fiza, @now)
      later = DateTime.add(@now, 121, :second)

      assert Extension.connect(code, %{"extension_version" => "0.1.0"}, @client, later) ==
               {:error, :token_invalid}

      assert Extension.connect("not-a-code", %{}, @client, @now) == {:error, :token_invalid}
      assert Extension.connect(nil, %{}, @client, @now) == {:error, :token_invalid}
    end

    test "the extension's version is required", c do
      {:ok, %{code: code}} = Extension.connect_code(c.s_fiza, @now)

      assert Extension.connect(code, %{}, @client, @now) ==
               {:error, {:missing, [:extension_version]}}
    end

    test "a code of somebody who is no longer staff is token_invalid", c do
      {:ok, %{code: code}} = Extension.connect_code(scope_for(c.muaz), @now)

      {:ok, _left} =
        c.backend.id |> Data.Teams.get_open_member(c.muaz.id) |> Data.Teams.leave(@now)

      assert Extension.connect(code, %{"extension_version" => "0.1.0"}, @client, @now) ==
               {:error, :token_invalid}
    end
  end

  describe "tokens stay in their own app" do
    test "a device's refresh works only as ext, and keeps the device", c do
      {:ok, %{device: device, tokens: tokens}} = connect(c.s_fiza)

      assert Guardian.exchange_refresh_token(tokens.refresh_token, "team") ==
               {:error, :invalid_refresh_token}

      assert Guardian.exchange_refresh_token(tokens.refresh_token, "client") ==
               {:error, :invalid_refresh_token}

      assert {:ok, fresh} = Guardian.exchange_refresh_token(tokens.refresh_token, "ext")
      {:ok, claims} = Guardian.decode_and_verify(fresh.access_token)
      assert claims["sid"] == device.id
    end

    test "a console token never refreshes as ext", c do
      {:ok, console} = Guardian.tokens_for(c.fiza, %{"dev" => %{"app" => "team"}})

      assert Guardian.exchange_refresh_token(console.refresh_token, "ext") ==
               {:error, :invalid_refresh_token}

      assert {:ok, _pair} = Guardian.exchange_refresh_token(console.refresh_token, "team")
    end

    test "/me/sessions leaves the extension's sessions out", c do
      {:ok, _device} = connect(c.s_fiza)
      {:ok, _console} = Guardian.tokens_for(c.fiza, %{"dev" => %{"app" => "team"}})

      assert [%{device: %{"app" => "team"}}] = Accounts.list_sessions(c.s_fiza, nil, @now)
    end
  end

  describe "the device behind a token" do
    test "a live device of a live staff account", c do
      {:ok, %{device: device, scope: scope}} = connect(c.s_fiza)
      assert {:ok, %{id: id}} = Extension.live_device(scope, device.id)
      assert id == device.id

      assert Extension.live_device(scope, Ecto.UUID.generate()) == {:error, :unauthenticated}
      assert Extension.live_device(scope, nil) == {:error, :unauthenticated}
      # Someone else's device is not theirs.
      assert Extension.live_device(c.s_dawud, device.id) == {:error, :unauthenticated}
    end

    test "last seen moves at most once a minute", c do
      {:ok, %{device: device, scope: scope}} = connect(c.s_fiza)

      :ok = Extension.seen(scope, device, DateTime.add(@now, 30, :second))
      assert Data.Devices.get(device.organisation_id, device.id).last_seen_at == @now

      later = DateTime.add(@now, 61, :second)
      :ok = Extension.seen(scope, device, later)
      assert Data.Devices.get(device.organisation_id, device.id).last_seen_at == later
    end
  end

  describe "listing and disconnecting" do
    test "each person their own; all=true is the system admin's", c do
      {:ok, %{device: mine}} = connect(c.s_fiza)
      {:ok, %{device: hers}} = connect(scope_for(c.hira))

      assert {:ok, [%{id: id}]} = Extension.list(c.s_fiza, %{})
      assert id == mine.id
      assert Extension.list(c.s_fiza, %{"all" => "true"}) == {:error, :not_found}

      assert {:ok, all} = Extension.list(c.s_dawud, %{"all" => "true"})
      assert Enum.sort(Enum.map(all, & &1.id)) == Enum.sort([mine.id, hers.id])
    end

    test "disconnect deletes the tokens, sets revoked_at and is audited", c do
      {:ok, %{device: device, tokens: tokens, scope: scope}} = connect(c.s_fiza)
      later = DateTime.add(@now, 60, :second)

      assert {:ok, revoked} = Extension.disconnect(scope, device.id, later)
      assert revoked.revoked_at == later
      assert revoked.revoked_by_user_id == c.fiza.id

      assert Guardian.exchange_refresh_token(tokens.refresh_token, "ext") ==
               {:error, :invalid_refresh_token}

      assert Extension.live_device(scope, device.id) == {:error, :unauthenticated}
      assert {:ok, []} = Extension.list(c.s_fiza, %{})

      assert Repo.exists?(
               from(e in AuditEvent,
                 where: e.subject_id == ^device.id and e.action == "disconnected"
               )
             )

      # Gone is gone: a second disconnect finds nothing.
      assert Extension.disconnect(scope, device.id, later) == {:error, :not_found}
    end

    test "only the owner or the system admin disconnects", c do
      {:ok, %{device: device}} = connect(c.s_fiza)

      assert Extension.disconnect(scope_for(c.hira), device.id, @now) == {:error, :not_found}
      assert {:ok, %{revoked_by_user_id: by}} = Extension.disconnect(c.s_dawud, device.id, @now)
      assert by == c.dawud.id
    end
  end
end
