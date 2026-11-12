defmodule Core.Workers.MeetingReminder do
  @moduledoc """
  One meeting reminder (AQ-06 §8.3, QP6-16) on the `scheduling` queue,
  planned by `Core.Meetings.Reminders.plan/2` at 24 h, 1 h and 10 min
  before. Holds no rule — it hands the clock to
  `Core.Meetings.Reminders.remind/4` — and is idempotent: a meeting moved
  or cancelled since makes it do nothing, and a second run finds every
  notification ensured.
  """

  use Oban.Worker, queue: :scheduling, max_attempts: 3

  alias Core.Clock
  alias Core.Meetings.Reminders

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"meeting_id" => id, "offset" => offset, "starts_at" => at}}) do
    _done = Reminders.remind(id, offset, at, Clock.now())
    :ok
  end
end
