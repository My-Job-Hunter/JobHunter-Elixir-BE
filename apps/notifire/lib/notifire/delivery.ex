defmodule Notifire.Delivery do
  @moduledoc """
  Sending what the ledger says is due (AQ-08 §7.2, §11.4; mCart's
  `Notifire.Delivery.run/1`, over `notification_deliveries`).

  **The far side of the seam.** `core` and `notifire` are siblings, so
  `core` plans a notification's rows in its transaction and this reads
  them: the queue is the database. A mailer being down leaves rows waiting
  rather than failing the write that produced them.

  `run/2` takes the due `pending` push and email rows, oldest
  `deliver_after` first, at most 200, **each under `FOR UPDATE SKIP
  LOCKED` in its own transaction**, so two runs never take the same row.
  For each:
  - **the person has since turned the channel off** for the group →
    `skipped · preference_off`;
  - **an email whose notification was read** → `skipped · read`, except
    the `meetings` and `account` groups' (a meeting's email carries its
    invite, the digest is the point);
  - **push**: to every browser the person turned on in their app; sent if
    any took it; a 404 or 410 deletes that browser; none left (or no VAPID
    keys) → `skipped · no_target`; browsers left but every one refusing →
    a failure;
  - **email**: Swoosh, with a meeting's invite attached.

  **A failure is recorded, never swallowed**: `attempts` + 1 and the error
  kept (never a body); under three the row stays `pending`, due five
  minutes on; the third makes it `failed`. Each run also skips the
  extension's rows nobody claimed within a day (`no_target`).

  `deliver_after` is what quiet hours set, so a held row is simply not due
  yet: deferred, never dropped. Workers hold no rules: every rule is
  asserted here.
  """

  alias Data.Notifications
  alias Data.Notifications.{Deliveries, Delivery, Notification, Preferences}
  alias Data.Repo
  alias Notifire.Email
  alias Notifire.Mailer
  alias Notifire.Push

  require Logger

  @most 200
  @attempts 3
  @retry_s 5 * 60
  @email_always ~w(meetings account)

  @doc """
  Sends everything due at `now`. Answers `%{sent, skipped, failed}`
  (`failed` counts failed attempts, whether or not the row stays pending).
  `opts`: `mailer:` overrides the mailer's config, `push:` the push
  options (`send: true`).
  """
  @spec run(DateTime.t(), keyword()) :: %{
          sent: non_neg_integer(),
          skipped: non_neg_integer(),
          failed: non_neg_integer()
        }
  def run(%DateTime{} = now, opts \\ []) do
    tally = sweep(%{sent: 0, skipped: 0, failed: 0}, now, opts, @most)
    %{tally | skipped: tally.skipped + Deliveries.skip_unclaimed_for_system(now)}
  end

  defp sweep(tally, _now, _opts, 0), do: tally

  defp sweep(tally, now, opts, left) do
    {:ok, outcome} =
      Repo.transaction(fn ->
        case Deliveries.next_due_for_system(now) do
          nil -> :done
          row -> deliver(row, now, opts)
        end
      end)

    case outcome do
      :done -> tally
      outcome -> sweep(Map.update!(tally, outcome, &(&1 + 1)), now, opts, left - 1)
    end
  end

  @doc "Delivers one locked row. Answers `:sent`, `:skipped` or `:failed`."
  @spec deliver(Delivery.t(), DateTime.t(), keyword()) :: :sent | :skipped | :failed
  def deliver(%Delivery{notification: %Notification{} = n} = row, now, opts) do
    group = n.notification_kind.notification_group
    who = Notifications.recipient(row.user_id)

    cond do
      is_nil(who) -> skip(row, :no_target, now)
      switched_off?(row, group) -> skip(row, :preference_off, now)
      read_first?(row, n, group) -> skip(row, :read, now)
      row.channel == :push -> push(row, n, who, now, opts)
      row.channel == :email -> email(row, n, who, now, opts)
    end
  end

  defp switched_off?(_row, %{can_disable: false}), do: false

  defp switched_off?(row, group) do
    Preferences.switches(row.user_id, group.key)[row.channel] == false
  end

  defp read_first?(%{channel: :email}, %{read_at: %DateTime{}}, group),
    do: group.key not in @email_always

  defp read_first?(_row, _n, _group), do: false

  defp push(row, n, who, now, opts) do
    payload = %{title: n.title, body: n.body, tag: n.id, url: Notification.open_path(n)}

    if Push.configured?() do
      result = Push.deliver(row.user_id, who.app, payload, now, Keyword.get(opts, :push, []))

      cond do
        result.sent > 0 -> sent(row, now)
        result.failed > 0 -> fail(row, result.error, now)
        true -> skip(row, :no_target, now)
      end
    else
      skip(row, :no_target, now)
    end
  end

  defp email(row, n, who, now, opts) do
    n
    |> Email.for_notification(who, row.ics)
    |> Mailer.deliver(Keyword.get(opts, :mailer, []))
    |> case do
      {:ok, _metadata} -> sent(row, now)
      {:error, reason} -> fail(row, describe(reason), now)
    end
  end

  defp describe(reason) when is_binary(reason), do: reason
  defp describe(reason), do: inspect(reason)

  defp sent(row, now) do
    :ok = Deliveries.mark_sent(row, now)
    :sent
  end

  defp skip(row, reason, now) do
    :ok = Deliveries.mark_skipped(row, reason, now)
    :skipped
  end

  defp fail(row, error, now) do
    Logger.warning("delivery #{row.id} (#{row.channel}) failed: #{error}")
    retry_at = DateTime.add(now, @retry_s, :second)
    _state = Deliveries.record_failure(row, error, now, retry_at, @attempts)
    :failed
  end
end
