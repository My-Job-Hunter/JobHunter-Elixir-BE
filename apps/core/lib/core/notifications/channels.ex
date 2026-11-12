defmodule Core.Notifications.Channels do
  @moduledoc """
  Which deliveries a new notification gets, and when (AQ-08 §7.1, §11.4):
  mCart's `put_alert` rule as a **pure** function, tested by a table over
  every kind and chair.

  **The ledger's channels** are `push`, `email` and `extension`. In-app is
  the notification row itself and `digest` is read by the scan, so neither
  is planned here. A channel is planned when:
  - the kind has it among its `default_channels`;
  - the person's switch for it in the kind's group isn't off (a group that
    can't be turned off ignores switches; QP8-6);
  - the person can have it (§4, QP8-7): push needs a browser turned on in
    their app at write time; the extension a connected device, and staff
    only; email always.

  **When** (`deliver_after`):
  - push and the extension at once;
  - email 10 minutes on (QP8-10), except the `meetings` and `account`
    groups', which go at once;
  - inside quiet hours, the window's end with `deferred: true` (QP8-8),
    unless the kind passes them.
  """

  alias Core.Notifications.QuietHours

  @ledger [:push, :email, :extension]
  @email_wait_s 10 * 60
  @email_at_once ~w(meetings account)

  @typedoc "The kind as planning reads it."
  @type kind :: %{
          required(:group) => String.t(),
          required(:channels) => [String.t()],
          required(:can_ignore_quiet_hours) => boolean(),
          optional(:can_disable) => boolean()
        }

  @typedoc "One planned row."
  @type planned :: %{channel: atom(), deliver_after: DateTime.t(), deferred: boolean()}

  @doc "The ledger's channels, in vocabulary order."
  def ledger, do: @ledger

  @doc "How long an email waits before it goes, in seconds (QP8-10)."
  def email_wait_s, do: @email_wait_s

  @doc "Whether this group's emails go at once and are never skipped as read (§11.4)."
  @spec email_at_once?(String.t()) :: boolean()
  def email_at_once?(group), do: group in @email_at_once

  @doc """
  The rows to write for one new notification.

  - `kind`: `%{group, channels, can_ignore_quiet_hours, can_disable}`;
  - `switches`: `%{push, email, extension}` (missing means on);
  - `targets`: what the person can have, `%{push, email, extension}`
    (missing means no);
  - `settings`: `%{quiet_hours_start, quiet_hours_end, zone}`.

  Answers `[%{channel, deliver_after, deferred}]`, in vocabulary order.

      iex> Core.Notifications.Channels.plan(
      ...>   %{group: "tasks", channels: ~w(inapp push), can_ignore_quiet_hours: false},
      ...>   %{},
      ...>   %{push: true, email: true},
      ...>   %{quiet_hours_start: nil, quiet_hours_end: nil, zone: "Etc/UTC"},
      ...>   ~U[2026-11-12 10:00:00Z]
      ...> )
      [%{channel: :push, deliver_after: ~U[2026-11-12 10:00:00Z], deferred: false}]
  """
  @spec plan(kind(), map(), map(), map(), DateTime.t()) :: [planned()]
  def plan(kind, switches, targets, settings, %DateTime{} = now) do
    for channel <- @ledger,
        Atom.to_string(channel) in kind.channels,
        on?(kind, switches, channel),
        Map.get(targets, channel, false) do
      timing(kind, channel, settings, now)
    end
  end

  defp on?(kind, switches, channel) do
    Map.get(kind, :can_disable, true) == false or Map.get(switches, channel, true) != false
  end

  defp timing(kind, channel, settings, now) do
    at = if channel == :email, do: email_at(kind, now), else: now
    hold(kind, channel, at, settings)
  end

  defp email_at(kind, now) do
    if email_at_once?(kind.group), do: now, else: DateTime.add(now, @email_wait_s, :second)
  end

  @doc """
  When a row due at `at` may go under the person's quiet hours, for a kind
  that does not pass them: `%{channel, deliver_after, deferred}`. Also what
  a changed window re-plans a held row by (§11.4).
  """
  @spec hold(kind(), atom(), DateTime.t(), map()) :: planned()
  def hold(kind, channel, %DateTime{} = at, settings) do
    held =
      with false <- kind.can_ignore_quiet_hours,
           %Time{} = from <- settings[:quiet_hours_start],
           %Time{} = until <- settings[:quiet_hours_end] do
        QuietHours.deliver_after(at, from, until, settings[:zone] || "Etc/UTC")
      else
        _passes_or_off -> nil
      end

    case held do
      nil -> %{channel: channel, deliver_after: at, deferred: false}
      opens -> %{channel: channel, deliver_after: opens, deferred: true}
    end
  end
end
