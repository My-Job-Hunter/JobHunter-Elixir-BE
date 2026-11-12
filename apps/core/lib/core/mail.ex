defmodule Core.Mail do
  @moduledoc """
  The one way `core` asks for a message to be sent (mCart's seam;
  CONVENTIONS §7). `core` may not name a `notifire` module, so the worker for
  each kind is read from `config :core, :mail_workers` and the message is a
  job: `Oban.Job.new/2`, never `Worker.new/1`.

  ## Kinds in P1

  | Kind | Carries | Worker |
  |---|---|---|
  | `:invitation` | the invitation id; the code is in the row | `Notifire.Workers.InvitationWorker` |
  | `:password_reset` | the token id and **the token as the secret** | `Notifire.Workers.PasswordResetWorker` |
  | `:email_change` | the token id and the token | `Notifire.Workers.EmailChangeWorker` |

  `enqueue/1` never returns an error the caller has to handle: a request
  that succeeded must not be failed by a mail job that could not be written.
  """

  alias Data.Mail.Command

  require Logger

  @queue :emails
  @max_attempts 3

  @doc "Enqueues one message; `:ok` whatever happened, loudly in the log otherwise."
  @spec enqueue(Command.t()) :: :ok
  def enqueue(%Command{} = command) do
    case worker_for(command.kind) do
      nil ->
        Logger.warning("no mail worker configured for #{inspect(command.kind)}")
        :ok

      worker ->
        insert(command, worker)
    end
  end

  @doc "Builds and enqueues in one step, raising on a command that cannot be built."
  @spec enqueue!(map()) :: :ok
  def enqueue!(params), do: params |> Command.new!() |> enqueue()

  @doc "The worker module for a kind, or `nil`. Public so a test can assert wiring."
  @spec worker_for(atom()) :: module() | nil
  def worker_for(kind), do: :core |> Application.get_env(:mail_workers, []) |> Keyword.get(kind)

  defp insert(command, worker) do
    command
    |> Command.to_job_args()
    |> Oban.Job.new(worker: worker, queue: @queue, max_attempts: @max_attempts)
    |> Oban.insert()
    |> case do
      {:ok, _job} ->
        :ok

      {:error, reason} ->
        Logger.error("could not enqueue #{inspect(command.kind)} mail: #{inspect(reason)}")
        :ok
    end
  end
end
