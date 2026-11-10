defmodule Data.AccountsTest do
  use Data.DataCase, async: true

  alias Data.Accounts
  alias Data.Accounts.User
  alias Data.Accounts.UserToken

  @now ~U[2026-11-09 10:00:00.000000Z]

  describe "register_user" do
    test "makes a person and an account in one transaction, the address lowered" do
      assert {:ok, user} =
               Accounts.register_user(%{
                 email: "Dawud@Example.com",
                 display_name: "Dawud",
                 password: "a fine long password"
               })

      assert user.email == "dawud@example.com"
      assert user.person.display_name == "Dawud"
      assert user.person.timezone == "Asia/Karachi"
      assert User.valid_password?(user, "a fine long password")
      refute User.valid_password?(user, "wrong")
    end

    test "the person's errors ride on the one changeset; a taken address is refused" do
      assert {:error, changeset} =
               Accounts.register_user(%{email: "x@example.com", display_name: "  "})

      assert errors_on(changeset).display_name
      assert Repo.aggregate(User, :count) == 0

      user_fixture(email: "taken@example.com")

      assert {:error, changeset} =
               Accounts.register_user(%{email: "TAKEN@example.com", display_name: "Two"})

      assert errors_on(changeset).email
    end

    test "an account made without a password (Google) has none and cannot sign in by password" do
      {:ok, user} =
        Accounts.register_user(%{
          email: unique_email(),
          display_name: "G",
          email_confirmed_at: @now
        })

      assert user.hashed_password == nil
      refute User.valid_password?(user, "anything at all")
    end
  end

  describe "reads" do
    test "by id, by email (any case), by identity" do
      user = user_fixture(email: "Hira@Example.com")
      assert Accounts.get_user(user.id).id == user.id
      assert Accounts.get_user("nonsense") == nil
      assert Accounts.get_user_by_email("HIRA@example.com").id == user.id
      assert Accounts.get_user_by_identity(:google, "sub-1") == nil
      {:ok, _identity} = Accounts.link_identity(user, :google, "sub-1", user.email, @now)
      assert Accounts.get_user_by_identity(:google, "sub-1").id == user.id

      assert {:error, _changeset} =
               Accounts.link_identity(user_fixture(), :google, "sub-1", nil, @now)
    end
  end

  describe "settings" do
    test "defaults when no row, then the row" do
      user = user_fixture()
      assert Accounts.get_settings(user.id).theme == :system
      assert {:ok, _row} = Accounts.put_settings(user.id, %{theme: :dark})
      assert Accounts.get_settings(user.id).theme == :dark
      assert {:ok, row} = Accounts.put_settings(user.id, %{digest_on: false})
      assert row.theme == :dark and row.digest_on == false
    end
  end

  describe "tokens" do
    test "the digest is stored, the plaintext is not; a live lookup finds it until used or expired" do
      user = user_fixture()

      assert {:ok, {token, row}} =
               Accounts.create_token(user, :reset_password, DateTime.add(@now, 3600, :second))

      assert row.token_digest == UserToken.hash(token)
      assert Accounts.get_live_token(token, [:reset_password], @now).id == row.id
      assert Accounts.get_live_token(token, [:change_email], @now) == nil

      assert Accounts.get_live_token(token, [:reset_password], DateTime.add(@now, 3601, :second)) ==
               nil

      assert Accounts.consume_tokens(user, [:reset_password], @now) == 1
      assert Accounts.get_live_token(token, [:reset_password], @now) == nil
      assert Accounts.get_token_for_system(row.id) == nil
    end

    test "a change needs a new address, a reset must not carry one (the CHECK)" do
      user = user_fixture()

      assert {:ok, {_token, row}} =
               Accounts.create_token(user, :change_email, @now, new_email: "New@Example.com")

      assert row.new_email == "new@example.com"

      assert {:error, _changeset} =
               Accounts.create_token(user, :reset_password, @now, new_email: "x@example.com")

      assert {:error, _changeset} = Accounts.create_token(user, :change_email, @now)
    end

    test "confirm_email moves the login and refuses a taken address" do
      user = user_fixture()

      {:ok, {_token, row}} =
        Accounts.create_token(user, :change_email, @now, new_email: "moved@example.com")

      assert {:ok, moved} = Accounts.confirm_email(row, @now)
      assert moved.email == "moved@example.com" and moved.email_confirmed_at == @now

      other = user_fixture()

      {:ok, {_token, row}} =
        Accounts.create_token(other, :change_email, @now, new_email: "moved@example.com")

      assert Accounts.confirm_email(row, @now) == {:error, :email_taken}
    end
  end

  test "phone-less, person-first: deleting a person with an account is refused" do
    user = user_fixture()
    assert_raise Ecto.ConstraintError, fn -> Repo.delete!(user.person) end
  end
end
