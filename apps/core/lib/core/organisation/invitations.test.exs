defmodule Core.Organisation.InvitationsTest do
  @moduledoc """
  The invitation's life: issued, open, resent, revoked, expired, accepted
  (by a new person, with Google, by an existing account). `async: false`
  for the Google tests, which swap global config.
  """

  use Core.CoreCase, async: false
  use Oban.Testing, repo: Data.Repo

  alias Core.Organisation.Invitations
  alias Data.Audit
  alias Data.Invitations.Invitation

  @now ~U[2026-11-09 10:00:00.000000Z]
  @later ~U[2026-11-17 10:00:00.000000Z]

  setup do
    org = organisation_fixture()
    backend = team_fixture(org, name: "Backend squad")
    frontend = team_fixture(org, name: "Frontend squad")
    admin = admin_fixture(org)
    lead = member_fixture(backend, :lead)

    %{
      org: org,
      backend: backend,
      frontend: frontend,
      admin: scope_for(admin),
      lead: scope_for(lead),
      lead_user: lead
    }
  end

  defp team_invite(scope, team, attrs \\ %{}) do
    Invitations.issue(
      scope,
      Map.merge(
        %{
          "kind" => "team_member",
          "email" => unique_email(),
          "invited_name" => "Hira Khan",
          "team_id" => team.id,
          "role" => "lead"
        },
        attrs
      ),
      @now
    )
  end

  describe "issue" do
    test "an admin invitation by an admin: a code of the right shape, a week, a mail, an audit row",
         %{org: org, admin: admin} do
      assert {:ok, inv, :issued} =
               Invitations.issue(
                 admin,
                 %{"kind" => "admin", "email" => "Dawud@Example.com", "invited_name" => "Dawud"},
                 @now
               )

      assert Regex.match?(Invitation.code_shape(), inv.code)
      assert inv.email == "dawud@example.com"
      assert inv.expires_at == DateTime.add(@now, 7, :day)
      assert inv.invited_by_user_id == admin.user.id
      assert Invitations.accept_url(inv) == "http://localhost:5800/invite/#{inv.code}"
      assert [%{action: "invited"}] = Audit.list_for_subject(org.id, "invitations", inv.id)
      assert_enqueued(worker: Notifire.Workers.InvitationWorker, args: %{"subject_id" => inv.id})
    end

    test "a team invitation by a lead; a lead may not invite an admin or above lead", %{
      lead: lead,
      backend: backend
    } do
      assert {:ok, inv, :issued} = team_invite(lead, backend)
      assert inv.kind == :team_member and inv.role == :lead and inv.team_id == backend.id

      assert {:error, {:forbidden, _words}} =
               Invitations.issue(lead, %{"kind" => "admin", "email" => unique_email()}, @now)

      assert {:error, :role_above_yours} = team_invite(lead, backend, %{"role" => "manager"})
    end

    test "a team the caller cannot see, or no team, is not found; a bad kind is missing", %{
      lead: lead,
      frontend: frontend
    } do
      assert team_invite(lead, frontend) == {:error, :not_found}

      assert Invitations.issue(
               lead,
               %{"kind" => "team_member", "email" => unique_email(), "role" => "lead"},
               @now
             ) == {:error, :not_found}

      assert Invitations.issue(lead, %{"kind" => "pirate", "email" => unique_email()}, @now) ==
               {:error, {:missing, :kind}}
    end

    test "a customer invitation: a lead of a serving team issues it, with the customer's address; an unknown customer is not found",
         %{admin: admin, lead: lead, backend: backend, frontend: frontend} do
      customer = customer_fixture(admin.organisation, [backend], display_name: "Tanweer")
      other = customer_fixture(admin.organisation, [frontend])

      params = %{"kind" => "customer", "email" => customer.email, "customer_id" => customer.id}

      assert {:ok, %Invitation{kind: :customer} = inv, :issued} =
               Invitations.issue(lead, params, @now)

      assert inv.customer_id == customer.id

      assert {:ok, %{customer_name: "Tanweer", team_name: nil}} =
               Invitations.preview(inv.code, @now)

      assert Invitations.issue(lead, %{params | "customer_id" => other.id}, @now) ==
               {:error, :not_found}

      assert Invitations.issue(admin, %{params | "customer_id" => Ecto.UUID.generate()}, @now) ==
               {:error, :not_found}
    end

    test "a second invitation for the same target is the open one, mailed again; lapsed, it is re-issued",
         %{admin: admin, backend: backend} do
      email = unique_email()
      {:ok, first, :issued} = team_invite(admin, backend, %{"email" => email})
      assert {:ok, same, :open} = team_invite(admin, backend, %{"email" => email})
      assert same.id == first.id

      {:ok, lapsed, status} =
        Invitations.issue(
          admin,
          %{"kind" => "team_member", "email" => email, "team_id" => backend.id, "role" => "lead"},
          @later
        )

      assert status == :reissued
      assert lapsed.id == first.id
      assert lapsed.expires_at == DateTime.add(@later, 7, :day)

      # A different team is a different target.
      assert {:ok, other, :issued} =
               team_invite(admin, team_fixture(admin.organisation), %{"email" => email})

      refute other.id == first.id
    end

    test "an invalid email or an unknown role is a changeset", %{admin: admin, backend: backend} do
      assert {:error, %Ecto.Changeset{}} =
               team_invite(admin, backend, %{"email" => "not-an-address"})

      assert {:error, %Ecto.Changeset{}} = team_invite(admin, backend, %{"role" => "boss"})
    end
  end

  describe "list, resend and revoke" do
    test "an admin lists all, a lead their teams'; state=open drops the closed", %{
      admin: admin,
      lead: lead,
      backend: backend,
      frontend: frontend
    } do
      {:ok, a, _} =
        Invitations.issue(admin, %{"kind" => "admin", "email" => unique_email()}, @now)

      {:ok, b, _} = team_invite(admin, backend)
      {:ok, f, _} = team_invite(admin, frontend)
      {:ok, _revoked} = Invitations.revoke(admin, f.id, @now)

      assert {:ok, all} = Invitations.list(admin)
      assert Enum.map(all, & &1.id) |> Enum.sort() == Enum.sort([a.id, b.id, f.id])
      assert {:ok, open} = Invitations.list(admin, %{"state" => "open"})
      assert Enum.map(open, & &1.id) |> Enum.sort() == Enum.sort([a.id, b.id])
      assert {:ok, [mine]} = Invitations.list(lead)
      assert mine.id == b.id

      assert {:error, {:forbidden, _words}} =
               Invitations.list(scope_for(member_fixture(backend, :member)))
    end

    test "resend gives a fresh week and mails again; revoke closes it; neither works twice", %{
      org: org,
      admin: admin,
      backend: backend
    } do
      {:ok, inv, _} = team_invite(admin, backend)

      assert {:ok, resent} = Invitations.resend(admin, inv.id, @later)
      assert resent.expires_at == DateTime.add(@later, 7, :day)

      assert length(
               all_enqueued(
                 worker: Notifire.Workers.InvitationWorker,
                 args: %{"subject_id" => inv.id}
               )
             ) == 2

      assert {:ok, revoked} = Invitations.revoke(admin, inv.id, @later)
      assert revoked.revoked_at == @later
      assert Invitations.revoke(admin, inv.id, @later) == {:error, :invitation_invalid}
      assert Invitations.resend(admin, inv.id, @later) == {:error, :invitation_invalid}

      assert Enum.map(Audit.list_for_subject(org.id, "invitations", inv.id), & &1.action) == [
               "invited",
               "resent",
               "revoked"
             ]
    end

    test "a lead revokes their team's, not the other team's nor an admin's", %{
      admin: admin,
      lead: lead,
      backend: backend,
      frontend: frontend
    } do
      {:ok, mine, _} = team_invite(admin, backend)
      {:ok, theirs, _} = team_invite(admin, frontend)

      {:ok, top, _} =
        Invitations.issue(admin, %{"kind" => "admin", "email" => unique_email()}, @now)

      assert {:ok, _revoked} = Invitations.revoke(lead, mine.id, @now)
      assert Invitations.revoke(lead, theirs.id, @now) == {:error, :not_found}
      assert Invitations.revoke(lead, top.id, @now) == {:error, :not_found}
      assert Invitations.revoke(lead, Ecto.UUID.generate(), @now) == {:error, :not_found}
    end
  end

  describe "preview" do
    test "says what the invitation is, by state", %{admin: admin, backend: backend} do
      {:ok, inv, _} = team_invite(admin, backend, %{"email" => "hira@example.com"})

      assert {:ok, preview} = Invitations.preview(inv.code, @now)
      assert preview.kind == :team_member
      assert preview.organisation_name == admin.organisation.name
      assert preview.team_name == "Backend squad"
      assert preview.role == :lead
      assert preview.invited_name == "Hira Khan"
      assert preview.email == "hira@example.com"
      assert preview.has_account == false
      assert preview.invited_by == "Test Person"

      user_fixture(email: "hira@example.com")
      assert {:ok, %{has_account: true}} = Invitations.preview(String.downcase(inv.code), @now)

      assert Invitations.preview(inv.code, @later) ==
               {:error, {:invitation_expired, inv.expires_at}}

      assert Invitations.preview("ZZ-ZZZZ", @now) == {:error, :invitation_invalid}
      assert Invitations.preview("nonsense", @now) == {:error, :invitation_invalid}

      {:ok, _revoked} = Invitations.revoke(admin, inv.id, @now)
      assert Invitations.preview(inv.code, @now) == {:error, :invitation_invalid}
    end
  end

  describe "accept" do
    test "a new person: name and password make the account, the role and the sign-in; the code is spent",
         %{org: org, admin: admin, backend: backend} do
      {:ok, inv, _} = team_invite(admin, backend, %{"email" => "Hira@Example.com"})

      assert {:ok, %{user: user, landing: "/", how: :created}} =
               Invitations.accept(
                 inv.code,
                 %{"name" => "Hira Khan", "password" => "a fine long password"},
                 now: @now
               )

      assert user.email == "hira@example.com"
      assert user.person.display_name == "Hira Khan"
      assert user.person.timezone == org.timezone
      assert Data.Teams.get_open_member(backend.id, user.id).role == :lead

      assert {:ok, _signed} =
               Core.Accounts.sign_in("hira@example.com", "a fine long password", @now)

      assert Invitations.preview(inv.code, @now) == {:error, :invitation_used}

      assert Invitations.accept(
               inv.code,
               %{"name" => "Again", "password" => "a fine long password"},
               now: @now
             ) ==
               {:error, :invitation_used}

      actions = org.id |> Audit.list_for_subject("invitations", inv.id) |> Enum.map(& &1.action)
      assert actions == ["invited", "accepted"]

      assert [%{action: "created", via: :system} | _signed_in] =
               Audit.list_for_subject(org.id, "users", user.id)
    end

    test "an admin invitation makes an admin; the invited name stands in for a missing one", %{
      org: org,
      admin: admin
    } do
      {:ok, inv, _} =
        Invitations.issue(
          admin,
          %{"kind" => "admin", "email" => unique_email(), "invited_name" => "Dawud Kalim"},
          @now
        )

      assert {:ok, %{user: user}} =
               Invitations.accept(inv.code, %{"password" => "a fine long password"}, now: @now)

      assert user.person.display_name == "Dawud Kalim"
      assert Data.Organisations.get_admin(org.id, user.id)
    end

    test "a weak password is refused and the invitation stays open", %{
      admin: admin,
      backend: backend
    } do
      {:ok, inv, _} = team_invite(admin, backend)

      assert Invitations.accept(inv.code, %{"name" => "Hira", "password" => "short"}, now: @now) ==
               {:error, :password_too_weak}

      assert Invitations.accept(inv.code, %{"name" => "Hira"}, now: @now) ==
               {:error, :password_too_weak}

      assert {:ok, %{state: _}} =
               {:ok, %{state: Invitation.state(Data.Invitations.get_by_code(inv.code), @now)}}

      assert Invitation.state(Data.Invitations.get_by_code(inv.code), @now) == :open
    end

    test "an existing account must sign in to accept, then accepts with one press", %{
      admin: admin,
      backend: backend,
      lead_user: lead_user
    } do
      {:ok, inv, _} =
        team_invite(admin, team_fixture(admin.organisation), %{"email" => lead_user.email})

      assert Invitations.accept(inv.code, %{"name" => "x", "password" => "a fine long password"},
               now: @now
             ) == {:error, :email_taken}

      other = user_fixture()

      assert {:error, {:forbidden, words}} =
               Invitations.accept(inv.code, %{}, current_user: other, now: @now)

      assert words =~ lead_user.email

      assert {:ok, %{user: user, how: :joined}} =
               Invitations.accept(inv.code, %{}, current_user: lead_user, now: @now)

      assert user.id == lead_user.id
      assert Data.Teams.get_open_member(inv.team_id, user.id).role == :lead
      # Still a lead of the first team too.
      assert Data.Teams.get_open_member(backend.id, user.id)
    end

    test "expired and revoked codes say why", %{admin: admin, backend: backend} do
      {:ok, inv, _} = team_invite(admin, backend)

      assert Invitations.accept(inv.code, %{"name" => "x", "password" => "a fine long password"},
               now: @later
             ) == {:error, {:invitation_expired, inv.expires_at}}

      {:ok, _revoked} = Invitations.revoke(admin, inv.id, @now)

      assert Invitations.accept(inv.code, %{"name" => "x", "password" => "a fine long password"},
               now: @now
             ) == {:error, :invitation_invalid}

      assert Invitations.accept("ZZ-ZZZZ", %{}, now: @now) == {:error, :invitation_invalid}
    end

    test "with Google (the stand-in): the address must match; a new account has no password and a linked identity",
         %{admin: admin, backend: backend} do
      original = Application.get_env(:core, :google)
      Application.put_env(:core, :google, Keyword.merge(original, client_id: nil, stand_in: true))
      on_exit(fn -> Application.put_env(:core, :google, original) end)

      {:ok, inv, _} = team_invite(admin, backend, %{"email" => "fiza@example.com"})

      assert Invitations.accept(inv.code, %{"id_token" => "dev:someone.else@example.com"},
               now: @now
             ) == {:error, :invalid_credentials}

      assert Invitations.accept(inv.code, %{"id_token" => "garbage"}, now: @now) ==
               {:error, :invalid_credentials}

      assert {:ok, %{user: user, how: :created}} =
               Invitations.accept(inv.code, %{"id_token" => "dev:fiza@example.com"}, now: @now)

      assert user.hashed_password == nil
      assert user.email_confirmed_at == @now
      assert Data.Accounts.get_user_by_identity(:google, "dev:fiza@example.com").id == user.id
      assert {:ok, _signed} = Core.Accounts.google_sign_in("dev:fiza@example.com", @now)

      # An existing account accepting with Google links the identity.
      {:ok, second, _} =
        team_invite(admin, team_fixture(admin.organisation), %{"email" => "fiza@example.com"})

      assert {:ok, %{how: :joined}} =
               Invitations.accept(second.code, %{"id_token" => "dev:fiza@example.com"}, now: @now)
    end
  end
end
