defmodule Core.AccountsTest do
  @moduledoc """
  Signing in, the sessions, the account page and suspension. The Google
  stand-in is `async: false` because it swaps global config.
  """

  use Core.CoreCase, async: false

  alias Core.Accounts
  alias Core.Auth.Guardian
  alias Data.Accounts.Person
  alias Data.Audit

  @now ~U[2026-11-09 10:00:00.000000Z]

  setup do
    org = organisation_fixture()
    admin = admin_fixture(org)
    %{org: org, admin: admin, scope: scope_for(admin)}
  end

  describe "sign_in" do
    test "a right password admits and records the sign-in", %{org: org, admin: admin} do
      assert {:ok, user} = Accounts.sign_in(admin.email, valid_password(), @now)
      assert user.id == admin.id
      assert user.last_signed_in_at == @now

      assert [%{action: "signed_in", actor_user_id: actor}] =
               Audit.list_for_subject(org.id, "users", admin.id)

      assert actor == admin.id
    end

    test "the address is matched in any case" do
      user = user_fixture(email: "Mixed.Case@Example.com")
      assert {:ok, _user} = Accounts.sign_in("mixed.case@example.com", valid_password(), @now)
      assert {:ok, _user} = Accounts.sign_in("MIXED.CASE@EXAMPLE.COM", valid_password(), @now)
      assert user.email == "mixed.case@example.com"
    end

    test "the same answer for a wrong email and a wrong password", %{admin: admin} do
      assert Accounts.sign_in(admin.email, "wrong password here", @now) ==
               {:error, :invalid_credentials}

      assert Accounts.sign_in("nobody@example.com", valid_password(), @now) ==
               {:error, :invalid_credentials}

      assert Accounts.sign_in(nil, valid_password(), @now) == {:error, :invalid_credentials}
      assert Accounts.sign_in(admin.email, "", @now) == {:error, :invalid_credentials}
    end

    test "a suspended account is told so", %{admin: admin} do
      {:ok, _user} = Data.Accounts.set_suspended(admin, @now)
      assert Accounts.sign_in(admin.email, valid_password(), @now) == {:error, :account_suspended}
    end
  end

  describe "google_sign_in" do
    setup do
      original = Application.get_env(:core, :google)
      Application.put_env(:core, :google, Keyword.merge(original, client_id: nil, stand_in: true))
      on_exit(fn -> Application.put_env(:core, :google, original) end)
      :ok
    end

    test "links the identity on first use for an address that has an account (QP1-5)", %{
      admin: admin
    } do
      assert {:ok, user} = Accounts.google_sign_in("dev:#{admin.email}", @now)
      assert user.id == admin.id

      assert %{user_id: user_id} =
               Data.Accounts.get_user_by_identity(:google, "dev:#{admin.email}")
               |> then(&%{user_id: &1.id})

      assert user_id == admin.id
      assert Data.Accounts.get_user(admin.id).email_confirmed_at == @now

      # The second time, by the identity.
      assert {:ok, again} = Accounts.google_sign_in("dev:#{admin.email}", @now)
      assert again.id == admin.id
    end

    test "an address with no account is not a door" do
      assert Accounts.google_sign_in("dev:stranger@example.com", @now) ==
               {:error, :account_not_found}
    end

    test "a bad token is invalid credentials" do
      assert Accounts.google_sign_in("garbage", @now) == {:error, :invalid_credentials}
      assert Accounts.google_sign_in(nil, @now) == {:error, :invalid_credentials}
    end

    test "a suspended account stays out", %{admin: admin} do
      {:ok, _user} = Data.Accounts.set_suspended(admin, @now)
      assert Accounts.google_sign_in("dev:#{admin.email}", @now) == {:error, :account_suspended}
    end
  end

  describe "the loader" do
    test "answers an active account and refuses a suspended one", %{admin: admin} do
      assert {:ok, %{id: id}} = Accounts.load_user(admin.id)
      assert id == admin.id
      {:ok, _user} = Data.Accounts.set_suspended(admin, @now)
      assert Accounts.load_user(admin.id) == {:error, :not_found}
      assert Accounts.load_user(Ecto.UUID.generate()) == {:error, :not_found}
      assert Accounts.load_user("nonsense") == {:error, :not_found}
    end
  end

  describe "sessions" do
    test "are listed by sid, the current one marked, and ended one at a time", %{
      admin: admin,
      scope: scope
    } do
      {:ok, one} = Guardian.tokens_for(admin, %{"dev" => %{"app" => "team"}})
      {:ok, two} = Guardian.tokens_for(admin)
      {:ok, %{"sid" => sid_one}} = Guardian.decode_and_verify(one.access_token)

      sessions = Accounts.list_sessions(scope, sid_one, DateTime.utc_now())
      assert length(sessions) == 2
      assert [current] = Enum.filter(sessions, & &1.is_current)
      assert current.sid == sid_one
      assert current.device == %{"app" => "team"}

      assert Accounts.revoke_session(scope, sid_one) == :ok
      assert {:error, _gone} = Guardian.decode_and_verify(one.access_token)
      assert {:ok, _still} = Guardian.decode_and_verify(two.access_token)
      assert Accounts.revoke_session(scope, sid_one) == {:error, :not_found}
    end

    test "logout ends this session; logout_all ends every one", %{admin: admin, scope: scope} do
      {:ok, one} = Guardian.tokens_for(admin)
      {:ok, two} = Guardian.tokens_for(admin)
      {:ok, %{"sid" => sid}} = Guardian.decode_and_verify(one.access_token)

      assert Accounts.logout(scope, sid) == :ok
      assert {:error, _gone} = Guardian.decode_and_verify(one.refresh_token)
      assert {:ok, _still} = Guardian.decode_and_verify(two.access_token)

      assert Accounts.logout_all(scope) == :ok
      assert {:error, _gone} = Guardian.decode_and_verify(two.access_token)
      assert Accounts.list_sessions(scope, nil, DateTime.utc_now()) == []
    end
  end

  describe "me and update_me" do
    test "me carries the user, the roles with team names, settings and the organisation", %{
      org: org,
      admin: admin
    } do
      team = team_fixture(org, name: "Backend squad")
      member_fixture(team, :lead, admin)
      me = Accounts.me(scope_for(admin))

      assert me.user.id == admin.id
      assert me.user.person.display_name == "Test Person"
      assert me.roles.admin == true
      assert me.roles.teams == [%{team_id: team.id, name: "Backend squad", role: :lead}]
      assert me.roles.customer_id == nil
      assert me.settings.theme == :system
      assert me.organisation.id == org.id
    end

    test "update_me changes the person and audits it", %{org: org, admin: admin, scope: scope} do
      assert {:ok, me} =
               Accounts.update_me(scope, %{
                 "display_name" => "Dawud Kalim",
                 "given_name" => "Dawud",
                 "timezone" => "Europe/London",
                 "locale_code" => "ur"
               })

      assert me.user.person.display_name == "Dawud Kalim"
      assert me.user.person.timezone == "Europe/London"
      person_id = admin.person_id

      assert [
               %{
                 action: "updated",
                 before: %{"display_name" => "Test Person"},
                 after: %{"display_name" => "Dawud Kalim"}
               }
             ] =
               Audit.list_for_subject(org.id, "persons", person_id)
    end

    test "update_me refuses a bad zone, a blank name, and somebody else's photo", %{scope: scope} do
      assert {:error, %Ecto.Changeset{} = cs} =
               Accounts.update_me(scope, %{"timezone" => "Europe/Karachi"})

      assert "is not a known IANA timezone" in errors_on(cs).timezone
      assert {:error, %Ecto.Changeset{}} = Accounts.update_me(scope, %{"display_name" => "  "})

      assert Accounts.update_me(scope, %{"photo_media_id" => Ecto.UUID.generate()}) ==
               {:error, {:missing, :photo_media_id}}
    end

    test "update_me puts a confirmed photo on and takes it off", %{scope: scope} do
      jpeg = <<0xFF, 0xD8, 0xFF, 0xE0>> <> "bytes"

      {:ok, media, _t} =
        Core.Media.create(
          scope,
          %{"media_kind" => "photo", "content_type" => "image/jpeg", "byte_count" => 9},
          "/m"
        )

      :ok = Core.Media.store(scope, media.id, jpeg)
      {:ok, _c} = Core.Media.confirm(scope, media.id, %{}, @now)

      assert {:ok, me} = Accounts.update_me(scope, %{"photo_media_id" => media.id})
      assert Person.photo_media_id(me.user.person) == media.id
      assert {:ok, me} = Accounts.update_me(scope, %{"photo_media_id" => nil})
      assert Person.photo_media_id(me.user.person) == nil
    end
  end

  describe "put_settings" do
    test "writes the row on first write, with the defaults for the rest, and audits", %{
      org: org,
      admin: admin,
      scope: scope
    } do
      assert {:ok, settings} =
               Accounts.put_settings(scope, %{
                 "theme" => "dark",
                 "quiet_hours_start" => "22:00:00",
                 "quiet_hours_end" => "07:00:00"
               })

      assert settings.theme == :dark
      assert settings.digest_time == ~T[08:00:00]

      assert [%{action: "updated", before: %{"theme" => "system"}}] =
               Audit.list_for_subject(org.id, "user_settings", admin.id)
    end

    test "refuses an unknown theme and a half window", %{scope: scope} do
      assert {:error, %Ecto.Changeset{}} = Accounts.put_settings(scope, %{"theme" => "neon"})

      assert {:error, %Ecto.Changeset{} = cs} =
               Accounts.put_settings(scope, %{"quiet_hours_start" => "22:00:00"})

      assert errors_on(cs).quiet_hours_end
    end
  end

  describe "change_password" do
    test "behind the current one, held to the rule, audited; other sessions stay", %{
      org: org,
      admin: admin,
      scope: scope
    } do
      {:ok, tokens} = Guardian.tokens_for(admin)

      assert Accounts.change_password(scope, valid_password(), "a brand new passphrase") == :ok
      assert {:ok, _user} = Accounts.sign_in(admin.email, "a brand new passphrase", @now)
      assert {:ok, _still} = Guardian.decode_and_verify(tokens.access_token)

      assert Enum.any?(
               Audit.list_for_subject(org.id, "users", admin.id),
               &(&1.action == "password_changed")
             )
    end

    test "a wrong current password is a 422 on the field, a weak new one is too weak", %{
      scope: scope
    } do
      assert {:error, %Ecto.Changeset{} = cs} =
               Accounts.change_password(scope, "not it at all", "a brand new passphrase")

      assert errors_on(cs).current == ["is not right"]

      assert Accounts.change_password(scope, valid_password(), "short") ==
               {:error, :password_too_weak}
    end
  end

  describe "suspend" do
    test "by an admin: every token revoked, team rows kept, audited", %{org: org, scope: scope} do
      team = team_fixture(org)
      member = member_fixture(team, :member)
      {:ok, tokens} = Guardian.tokens_for(member)

      assert {:ok, suspended} = Accounts.suspend(scope, member.id, @now)
      assert suspended.suspended_at == @now
      assert {:error, _gone} = Guardian.decode_and_verify(tokens.access_token)
      assert Data.Teams.get_open_member(team.id, member.id)
      assert [%{action: "suspended"}] = Audit.list_for_subject(org.id, "users", member.id)

      assert {:ok, lifted} = Accounts.unsuspend(scope, member.id)
      assert lifted.suspended_at == nil
    end

    test "not by a team lead, not yourself, not somebody outside the organisation", %{
      org: org,
      admin: admin,
      scope: scope
    } do
      team = team_fixture(org)
      lead = member_fixture(team, :lead)
      member = member_fixture(team, :member)
      outsider = user_fixture()

      assert {:error, {:forbidden, _words}} =
               Accounts.suspend(scope_for(lead), member.id, @now)

      assert {:error, {:forbidden, _words}} = Accounts.suspend(scope, admin.id, @now)
      assert Accounts.suspend(scope, outsider.id, @now) == {:error, :not_found}
      assert Accounts.suspend(scope, Ecto.UUID.generate(), @now) == {:error, :not_found}
    end
  end
end
