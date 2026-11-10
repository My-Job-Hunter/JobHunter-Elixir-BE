defmodule Notifire.Workers.PasswordResetWorkerTest do
  use Notifire.NotifireCase, async: true

  alias Data.Mail.Command
  alias Notifire.Workers.EmailChangeWorker
  alias Notifire.Workers.InvitationWorker
  alias Notifire.Workers.PasswordResetWorker

  @now ~U[2026-11-09 10:00:00.000000Z]

  defp job(command), do: %Oban.Job{args: Command.to_job_args(Command.new!(command))}

  test "the reset worker delivers the mail and marks the row sent" do
    user = user_fixture()

    {:ok, {token, row}} =
      Data.Accounts.create_token(user, :reset_password, DateTime.add(@now, 1, :hour))

    assert PasswordResetWorker.perform(
             job(%{kind: :password_reset, subject_id: row.id, secret: token})
           ) == :ok

    assert_email_sent(subject: "Reset your Job Hunter password")
    assert Repo.get!(Data.Accounts.UserToken, row.id).sent_at
  end

  test "a consumed reset is nothing to send; unusable args are cancelled" do
    user = user_fixture()
    {:ok, {token, row}} = Data.Accounts.create_token(user, :reset_password, @now)
    Data.Accounts.consume_tokens(user, [:reset_password], @now)

    assert PasswordResetWorker.perform(
             job(%{kind: :password_reset, subject_id: row.id, secret: token})
           ) == :ok

    refute_email_sent()

    assert {:cancel, :invalid_args} =
             PasswordResetWorker.perform(%Oban.Job{args: %{"kind" => "password_reset"}})
  end

  test "the email change worker mails the new address" do
    user = user_fixture()

    {:ok, {token, row}} =
      Data.Accounts.create_token(user, :change_email, @now, new_email: "new@example.com")

    assert EmailChangeWorker.perform(
             job(%{kind: :email_change, subject_id: row.id, secret: token})
           ) == :ok

    assert_email_sent(to: {"Test Person", "new@example.com"})
  end

  test "the invitation worker mails an open invitation and skips a closed one" do
    org = organisation_fixture()
    inv = invitation_fixture(org)

    assert InvitationWorker.perform(job(%{kind: :invitation, subject_id: inv.id})) == :ok
    assert_email_sent(to: {"Invited Person", inv.email})

    {:ok, _revoked} = Data.Invitations.revoke(inv, @now)
    assert InvitationWorker.perform(job(%{kind: :invitation, subject_id: inv.id})) == :ok
    refute_email_sent()

    assert InvitationWorker.perform(job(%{kind: :invitation, subject_id: Ecto.UUID.generate()})) ==
             :ok
  end
end
