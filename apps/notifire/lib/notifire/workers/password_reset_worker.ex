defmodule Notifire.Workers.PasswordResetWorker do
  @moduledoc """
  Sends one password reset link (mCart's `PA3`). **A reset is the one
  message a row cannot reconstruct**: only the token's digest is stored, so
  the token travels in this job's args and is written nowhere else. What
  sits in a completed job is a dead string within the hour.
  """

  use Oban.Worker, queue: :emails, max_attempts: 3

  alias Data.Accounts
  alias Data.Accounts.UserToken
  alias Data.Mail.Command
  alias Notifire.Email
  alias Notifire.Mailer

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    case Command.from_job_args(args) do
      {:ok, %Command{subject_id: id, secret: token}} when is_binary(token) ->
        deliver(Accounts.get_token_for_system(id), token)

      _unusable ->
        Logger.error("password reset job has unusable args: #{inspect(Map.keys(args))}")
        {:cancel, :invalid_args}
    end
  end

  defp deliver(%UserToken{purpose: :reset_password} = row, token) do
    case row |> Email.password_reset(token) |> Mailer.deliver() do
      {:ok, _metadata} ->
        {:ok, _sent} = Accounts.mark_token_sent(row, DateTime.utc_now())
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp deliver(_consumed_or_gone, _token) do
    Logger.info("password reset consumed before delivery; nothing to send")
    :ok
  end
end
