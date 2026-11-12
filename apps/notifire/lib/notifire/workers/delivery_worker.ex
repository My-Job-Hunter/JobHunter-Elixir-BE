defmodule Notifire.Workers.DeliveryWorker do
  @moduledoc """
  The sweep that empties the ledger (AQ-08 §7.2, PLAN §15.7): **on write**,
  enqueued by `core` through its configured name (`config :core,
  :delivery_worker`), unique for two seconds, and **every five minutes** by
  the crontab (`config :core, Oban`), on the `notifications` queue.

  **Workers hold no rules** (CONVENTIONS §8). This one reads the clock —
  `Utils.Clock`, so it agrees with the dev clock a run moves (QP8-22) — or
  the `now` it was given, and calls `Notifire.Delivery.run/2`, which a test
  calls directly. Idempotent: a second run finds nothing due.
  """

  use Oban.Worker, queue: :notifications, max_attempts: 3

  alias Notifire.Delivery

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    {:ok, args |> Map.get("now") |> parse_now() |> Delivery.run()}
  end

  defp parse_now(nil), do: Utils.Clock.now()

  defp parse_now(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, at, _offset} -> at
      _invalid -> Utils.Clock.now()
    end
  end
end
