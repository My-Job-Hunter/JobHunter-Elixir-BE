defmodule Notifire.Workers.EmailChangeWorker do
  @moduledoc """
  Sends the link that proves a new address (AQ-01 §6.1 `POST /me/email`),
  to the **new** address. The token rides in the job's args, as a reset's does.
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
        Logger.error("email change job has unusable args: #{inspect(Map.keys(args))}")
        {:cancel, :invalid_args}
    end
  end

  defp deliver(%UserToken{purpose: :change_email} = row, token) do
    case row |> Email.email_change(token) |> Mailer.deliver() do
      {:ok, _metadata} ->
        {:ok, _sent} = Accounts.mark_token_sent(row, DateTime.utc_now())
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp deliver(_consumed_or_gone, _token) do
    Logger.info("email change consumed before delivery; nothing to send")
    :ok
  end
end
