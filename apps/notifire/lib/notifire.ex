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
  each looks like.

  ## In P8 (AQ-08 §7)

  The deliveries ledger is the seam: `core` plans a notification's rows in
  its transaction, and `Notifire.Delivery.run/2` (run by
  `Notifire.Workers.DeliveryWorker` on write and every five minutes) sends
  the due push and email rows. `Notifire.Push` is Web Push (mCart's, with
  the dev outbox `Notifire.Push.Outbox`); `Notifire.Email.for_notification/2`
  is a notification as mail. The extension's rows are claimed by its poll,
  in `core`.
  """
end
