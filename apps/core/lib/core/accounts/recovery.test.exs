defmodule Core.Accounts.RecoveryTest do
  use Core.CoreCase, async: true
  use Oban.Testing, repo: Data.Repo

  alias Core.Accounts.Recovery
  alias Core.Auth.Guardian
  alias Data.Accounts
  alias Data.Accounts.UserToken

  @now ~U[2026-11-09 10:00:00.000000Z]

  setup do
    org = organisation_fixture()
    user = admin_fixture(org)
    %{org: org, user: user, scope: scope_for(user)}
  end

  # The token itself only ever exists in the job's args.
  defp token_from_job(worker) do
    [job] = all_enqueued(worker: worker)
    {job.args["secret"], job.args["subject_id"]}
  end

  describe "request_password_reset" do
    test "writes a digest, mails the token through the seam, and answers :ok", %{user: user} do
      assert Recovery.request_password_reset(user.email, now: @now, requested_ip: "203.0.113.5") ==
               :ok

      {token, id} = token_from_job(Notifire.Workers.PasswordResetWorker)

      row = Repo.get!(UserToken, id)
      assert row.purpose == :reset_password
      assert row.token_digest == UserToken.hash(token)
      assert row.expires_at == DateTime.add(@now, 3600, :second)
      assert row.requested_ip == "203.0.113.5"
      refute String.contains?(inspect(row), token)
    end

    test "answers :ok for an unknown address and a suspended account, and mails nothing", %{
      user: user
    } do
      assert Recovery.request_password_reset("nobody@example.com", now: @now) == :ok
      {:ok, _user} = Accounts.set_suspended(user, @now)
      assert Recovery.request_password_reset(user.email, now: @now) == :ok
      assert Recovery.request_password_reset(nil) == :ok
      assert all_enqueued() == []
    end

    test "a second request consumes the first", %{user: user} do
      :ok = Recovery.request_password_reset(user.email, now: @now)
      [first] = all_enqueued()
      :ok = Recovery.request_password_reset(user.email, now: @now)

      assert Repo.get!(UserToken, first.args["subject_id"]).used_at == @now
      assert Accounts.get_live_token(first.args["secret"], [:reset_password], @now) == nil
    end
  end

  describe "reset_password" do
    test "sets the password, consumes the link and revokes every token", %{org: org, user: user} do
      {:ok, tokens} = Guardian.tokens_for(user)
      :ok = Recovery.request_password_reset(user.email, now: @now)
      {token, _id} = token_from_job(Notifire.Workers.PasswordResetWorker)

      assert {:ok, reset} = Recovery.reset_password(token, "a completely new one", @now)
      assert reset.id == user.id
      assert {:ok, _user} = Core.Accounts.sign_in(user.email, "a completely new one", @now)
      assert {:error, _gone} = Guardian.decode_and_verify(tokens.access_token)

      assert Recovery.reset_password(token, "a completely new one", @now) ==
               {:error, :token_invalid}

      assert Enum.any?(
               Data.Audit.list_for_subject(org.id, "users", user.id),
               &(&1.action == "password_reset")
             )
    end

    test "an expired, forged or missing token is the same answer; a weak password leaves the link alive",
         %{user: user} do
      :ok = Recovery.request_password_reset(user.email, now: @now)
      {token, _id} = token_from_job(Notifire.Workers.PasswordResetWorker)

      assert Recovery.reset_password(token, "short", @now) == {:error, :password_too_weak}

      assert Recovery.reset_password(
               token,
               "a completely new one",
               DateTime.add(@now, 3601, :second)
             ) == {:error, :token_invalid}

      assert Recovery.reset_password("forged", "a completely new one", @now) ==
               {:error, :token_invalid}

      assert Recovery.reset_password(nil, "a completely new one", @now) ==
               {:error, :token_invalid}
    end
  end

  describe "the email change" do
    test "mails the new address a link; confirming moves the login and audits", %{
      org: org,
      user: user,
      scope: scope
    } do
      assert Recovery.request_email_change(scope, "New.Address@Example.com", @now) == :ok
      {token, id} = token_from_job(Notifire.Workers.EmailChangeWorker)
      row = Repo.get!(UserToken, id)
      assert row.purpose == :change_email
      assert row.new_email == "new.address@example.com"
      assert row.expires_at == DateTime.add(@now, 86_400, :second)

      assert {:ok, changed} = Recovery.confirm_email_change(scope, token, @now)
      assert changed.email == "new.address@example.com"
      assert changed.email_confirmed_at == @now
      assert Recovery.confirm_email_change(scope, token, @now) == {:error, :token_invalid}

      assert Enum.any?(Data.Audit.list_for_subject(org.id, "users", user.id), fn e ->
               e.action == "email_changed" and e.after == %{"email" => "new.address@example.com"}
             end)
    end

    test "an address another account holds is taken", %{scope: scope} do
      other = user_fixture()
      assert Recovery.request_email_change(scope, other.email, @now) == {:error, :email_taken}
      assert Recovery.request_email_change(scope, nil, @now) == {:error, {:missing, :new_email}}
    end

    test "somebody else's token, or a dead one, is invalid", %{scope: scope} do
      other = user_fixture()
      :ok = Recovery.request_email_change(scope_for(other), "theirs@example.com", @now)
      {token, _id} = token_from_job(Notifire.Workers.EmailChangeWorker)

      assert Recovery.confirm_email_change(scope, token, @now) == {:error, :token_invalid}

      assert Recovery.confirm_email_change(scope_for(other), token, DateTime.add(@now, 2, :day)) ==
               {:error, :token_invalid}
    end

    test "a race to the address while the link sat in an inbox is email_taken", %{scope: scope} do
      :ok = Recovery.request_email_change(scope, "raced@example.com", @now)
      {token, _id} = token_from_job(Notifire.Workers.EmailChangeWorker)
      user_fixture(email: "raced@example.com")

      assert Recovery.confirm_email_change(scope, token, @now) == {:error, :email_taken}
    end
  end
end
