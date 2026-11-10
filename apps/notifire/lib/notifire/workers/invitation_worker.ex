defmodule Notifire.Workers.InvitationWorker do
  @moduledoc """
  Mails one invitation (JH-01 §6.2: *the mail goes out through `notifire`*).
  Enqueued by `core` through `Core.Mail`, named here only in config. The
  code is in the row, so the job carries only the id; a row that was revoked
  or accepted before delivery is nothing to send.
  """

  use Oban.Worker, queue: :emails, max_attempts: 3

  alias Data.Invitations
  alias Data.Invitations.Invitation
  alias Data.Mail.Command
  alias Notifire.Email
  alias Notifire.Mailer

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    case Command.from_job_args(args) do
      {:ok, %Command{subject_id: id}} -> deliver(Invitations.get_for_system(id))
      {:error, why} -> {:cancel, why}
    end
  end

  defp deliver(%Invitation{accepted_at: nil, revoked_at: nil} = invitation) do
    case invitation |> Email.invitation() |> Mailer.deliver() do
      {:ok, _metadata} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp deliver(_gone_or_closed) do
    Logger.info("invitation closed before delivery; nothing to send")
    :ok
  end
end
