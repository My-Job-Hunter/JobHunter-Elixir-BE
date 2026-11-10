defmodule Notifire do
  @moduledoc """
  Delivery: email (Swoosh), Web Push, and pushes to the extension (PLAN
  §11, §15.1).

  **A sibling of `core`, and neither calls the other.** `core` decides what to
  say and writes a row (or, for a message a row cannot reconstruct, enqueues
  a job naming a worker here through `config :core, :mail_workers`); this app
  delivers. A worker here is named to `core` in config, never in code.

  ## In P1

  Three workers, one per message: `Notifire.Workers.InvitationWorker`,
  `Notifire.Workers.PasswordResetWorker` and
  `Notifire.Workers.EmailChangeWorker`, with `Notifire.Email` saying what
  each looks like. The `notifications` table, the sweep (`DeliveryWorker`),
  the digest and Web Push arrive in P7 and P8.
  """
end
