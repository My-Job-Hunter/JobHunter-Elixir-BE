defmodule Data.Invitations.InvitationTest do
  use Data.DataCase, async: true

  alias Data.Invitations
  alias Data.Invitations.Invitation

  @now ~U[2026-11-09 10:00:00.000000Z]

  test "a generated code is XX-XXXX from the unambiguous alphabet" do
    for _n <- 1..200 do
      code = Invitation.generate_code()
      assert Regex.match?(Invitation.code_shape(), code), code
      refute String.contains?(code, ["0", "O", "1", "I"])
    end
  end

  test "state reads open, expired, accepted, revoked" do
    inv = %Invitation{expires_at: DateTime.add(@now, 1, :day)}
    assert Invitation.state(inv, @now) == :open
    assert Invitation.state(inv, DateTime.add(@now, 2, :day)) == :expired
    assert Invitation.state(%{inv | accepted_at: @now}, @now) == :accepted
    assert Invitation.state(%{inv | accepted_at: @now, revoked_at: @now}, @now) == :revoked
  end

  describe "the kind ties its fields (the CHECK and the changeset)" do
    setup do
      org = organisation_fixture()
      %{org: org, team: team_fixture(org)}
    end

    defp attrs(org, more) do
      Map.merge(
        %{
          organisation_id: org.id,
          code: Invitation.generate_code(),
          email: unique_email(),
          expires_at: @now
        },
        more
      )
    end

    test "a team invitation wants a team and a role, and no customer", %{org: org, team: team} do
      assert {:ok, _inv} =
               Invitations.create(
                 attrs(org, %{kind: :team_member, team_id: team.id, role: :lead})
               )

      assert {:error, cs} =
               Invitations.create(attrs(org, %{kind: :team_member, team_id: team.id}))

      assert errors_on(cs).role

      assert {:error, cs} =
               Invitations.create(
                 attrs(org, %{
                   kind: :team_member,
                   team_id: team.id,
                   role: :lead,
                   customer_id: Ecto.UUID.generate()
                 })
               )

      assert errors_on(cs).customer_id
    end

    test "an admin invitation names no team", %{org: org, team: team} do
      assert {:ok, _inv} = Invitations.create(attrs(org, %{kind: :admin}))
      assert {:error, cs} = Invitations.create(attrs(org, %{kind: :admin, team_id: team.id}))
      assert errors_on(cs).kind
    end

    test "a customer invitation wants a customer", %{org: org} do
      assert {:error, cs} = Invitations.create(attrs(org, %{kind: :customer}))
      assert errors_on(cs).customer_id
    end

    test "a code of the wrong shape is refused by the changeset and the database", %{org: org} do
      assert {:error, cs} = Invitations.create(attrs(org, %{kind: :admin, code: "0O-1I11"}))
      assert errors_on(cs).code
    end

    test "one open invitation per target: the three partial uniques", %{org: org, team: team} do
      email = unique_email()
      assert {:ok, first} = Invitations.create(attrs(org, %{kind: :admin, email: email}))

      assert {:error, cs} =
               Invitations.create(attrs(org, %{kind: :admin, email: String.upcase(email)}))

      assert errors_on(cs).email
      {:ok, _revoked} = Invitations.revoke(first, @now)
      assert {:ok, _again} = Invitations.create(attrs(org, %{kind: :admin, email: email}))

      assert {:ok, _one} =
               Invitations.create(
                 attrs(org, %{kind: :team_member, email: email, team_id: team.id, role: :member})
               )

      assert {:error, _cs} =
               Invitations.create(
                 attrs(org, %{kind: :team_member, email: email, team_id: team.id, role: :lead})
               )

      assert {:ok, _two} =
               Invitations.create(
                 attrs(org, %{
                   kind: :team_member,
                   email: email,
                   team_id: team_fixture(org).id,
                   role: :lead
                 })
               )
    end

    test "open_for finds the open one for a target, whatever its expiry", %{org: org, team: team} do
      email = unique_email()

      {:ok, inv} =
        Invitations.create(
          attrs(org, %{
            kind: :team_member,
            email: email,
            team_id: team.id,
            role: :member,
            expires_at: @now
          })
        )

      assert Invitations.open_for(org.id, :team_member, email, team.id).id == inv.id
      assert Invitations.open_for(org.id, :team_member, email, Ecto.UUID.generate()) == nil
      assert Invitations.open_for(org.id, :admin, email, nil) == nil
    end

    test "get_by_code is forgiving about case and spaces, and strict about shape", %{org: org} do
      inv = invitation_fixture(org)
      assert Invitations.get_by_code(" #{String.downcase(inv.code)} ").id == inv.id
      assert Invitations.get_by_code("not a code") == nil
      assert Invitations.get_by_code(nil) == nil
    end
  end
end
