defmodule Core.MailTest do
  use Core.CoreCase, async: true
  use Oban.Testing, repo: Data.Repo

  alias Core.Mail
  alias Data.Mail.Command

  test "every P1 kind has a worker named in config" do
    assert Mail.worker_for(:invitation) == Notifire.Workers.InvitationWorker
    assert Mail.worker_for(:password_reset) == Notifire.Workers.PasswordResetWorker
    assert Mail.worker_for(:email_change) == Notifire.Workers.EmailChangeWorker
    assert Mail.worker_for(:carrier_pigeon) == nil
  end

  test "enqueue! writes a job on the emails queue carrying the command" do
    id = Ecto.UUID.generate()

    assert Mail.enqueue!(%{kind: :password_reset, subject_id: id, secret: "tok"}) == :ok

    assert_enqueued(
      worker: Notifire.Workers.PasswordResetWorker,
      queue: :emails,
      args: %{"kind" => "password_reset", "subject_id" => id, "secret" => "tok", "options" => %{}}
    )
  end

  test "a kind nobody wired up is a warning, never an error for the caller" do
    assert ExUnit.CaptureLog.capture_log(fn ->
             assert Mail.enqueue(Command.new!(%{kind: :carrier_pigeon, subject_id: "x"})) == :ok
           end) =~ "no mail worker"
  end

  test "a command missing its subject raises at the call site" do
    assert_raise ArgumentError, fn -> Mail.enqueue!(%{kind: :invitation}) end
  end
end
