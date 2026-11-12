defmodule Core.Retention.Policy do
  @moduledoc """
  Retention (AQ-04B §7.1, QP4b-2…5, QP4b-23), **pure**: a lead or a job, the
  system's settings (`inactivity_days` 90, `warning_days` 7,
  `purge_after_days` 90), the organisation's zone and `now` in; a decision
  out. The sweeps (`Core.Retention`) hold no rule: they read rows, ask
  here, and write what is answered. The card, the Tracker row and the
  preview read the same functions, so "Archives in 23 days" and the sweep
  never disagree.

  | Step | Rule |
  |---|---|
  | **The quiet clock** | `last_activity_at`; on hold with an *until* day, the end of that day in the organisation's zone, if later (Q34) |
  | **Exempt** | `is_pinned` (Hired pins itself) from every step; an archived lead from the warning and the archive |
  | **Warn** | quiet `inactivity_days − warning_days` (83), once per quiet spell: no `archive_warned` since `last_activity_at` |
  | **Archive the lead** | quiet `inactivity_days` (90) |
  | **Archive the job** | no unarchived lead on it, and the job quiet `inactivity_days` by its own `last_activity_at`; a job with a live lead never archives |
  | **Purge the lead** | archived `purge_after_days` (90), not pinned: a fingerprint first, then the delete |
  | **Purge the job** | archived `purge_after_days` with no lead left |

  The card's warning shows from `inactivity_days − 30` quiet days (60 by
  default, PLAN §6.3's "amber from 60 days").
  """

  @day 86_400
  @card_lead_days 30

  @type settings :: %{
          inactivity_days: pos_integer(),
          warning_days: pos_integer(),
          purge_after_days: pos_integer()
        }

  # ── The quiet clock ─────────────────────────────────────────────────────────

  @doc """
  When the lead went quiet: `last_activity_at`, or — on hold with an *until*
  day — the end of that day in `zone`, whichever is later.
  """
  @spec quiet_since(map(), String.t()) :: DateTime.t()
  def quiet_since(lead, zone) do
    case hold_end(lead, zone) do
      %DateTime{} = ends ->
        if DateTime.after?(ends, lead.last_activity_at), do: ends, else: lead.last_activity_at

      nil ->
        lead.last_activity_at
    end
  end

  defp hold_end(%{state: :on_hold, hold_until_on: %Date{} = until}, zone),
    do: start_of(Date.add(until, 1), zone)

  defp hold_end(_lead, _zone), do: nil

  # ── A lead ──────────────────────────────────────────────────────────────────

  @doc """
  What the sweeps do to a lead at `now`: `:warn`, `:archive`, `:purge` or
  `:none`. `lead` carries `last_activity_at`, `state`, `hold_until_on`,
  `is_pinned` and `archived_at`; `warned_at` is the newest `archive_warned`
  event's time (or `nil`).
  """
  @spec lead_action(map(), DateTime.t() | nil, settings(), DateTime.t(), String.t()) ::
          :warn | :archive | :purge | :none
  def lead_action(lead, warned_at, settings, %DateTime{} = now, zone) do
    cond do
      lead.is_pinned ->
        :none

      not is_nil(lead.archived_at) ->
        if reached?(purge_at(lead, settings), now), do: :purge, else: :none

      reached?(archive_at(lead, settings, zone), now) ->
        :archive

      reached?(warn_at(lead, settings, zone), now) and not warned?(lead, warned_at) ->
        :warn

      true ->
        :none
    end
  end

  @doc "Whether the warning was already given in this quiet spell (QP4b-3)."
  @spec warned?(map(), DateTime.t() | nil) :: boolean()
  def warned?(_lead, nil), do: false

  def warned?(lead, %DateTime{} = warned_at),
    do: DateTime.compare(warned_at, lead.last_activity_at) != :lt

  @doc "When a live lead archives: quiet `inactivity_days`."
  @spec archive_at(map(), settings(), String.t()) :: DateTime.t()
  def archive_at(lead, settings, zone),
    do: add_days(quiet_since(lead, zone), settings.inactivity_days)

  @doc "When the warning is due: `warning_days` before the archive."
  @spec warn_at(map(), settings(), String.t()) :: DateTime.t()
  def warn_at(lead, settings, zone),
    do: add_days(archive_at(lead, settings, zone), -settings.warning_days)

  @doc "When an archived lead purges: `purge_after_days` after its archive."
  @spec purge_at(map(), settings()) :: DateTime.t()
  def purge_at(%{archived_at: %DateTime{} = at}, settings),
    do: add_days(at, settings.purge_after_days)

  @doc """
  The card's and the row's `quiet` (§7.5, §8.1): `%{since, archives_on, warn,
  purges_on}` — `purges_on` the day an archived, unpinned lead is cleared.
  `archives_on` is the day a live, unpinned lead archives (in `zone`), `nil`
  otherwise; `warn` is true from `inactivity_days − 30` quiet days.
  """
  @spec quiet(map(), settings(), DateTime.t(), String.t()) :: map()
  def quiet(lead, settings, %DateTime{} = now, zone) do
    since = quiet_since(lead, zone)

    if lead.is_pinned or not is_nil(lead.archived_at) do
      %{
        since: since,
        archives_on: nil,
        days_left: nil,
        warn: false,
        purges_on: purges_on(lead, settings, zone)
      }
    else
      from = add_days(since, max(settings.inactivity_days - @card_lead_days, 0))
      archives_on = day(archive_at(lead, settings, zone), zone)

      %{
        since: since,
        archives_on: archives_on,
        # Counted from the server's *now* (the dev clock's too), so "Archives in
        # 23 days" is the policy's word, never the browser's own date.
        days_left: max(Date.diff(archives_on, day(now, zone)), 0),
        warn: reached?(from, now),
        purges_on: nil
      }
    end
  end

  @doc "The day an archived lead purges, in `zone`."
  @spec purges_on(map(), settings(), String.t()) :: Date.t() | nil
  def purges_on(%{archived_at: %DateTime{}, is_pinned: false} = lead, settings, zone),
    do: day(purge_at(lead, settings), zone)

  def purges_on(_lead, _settings, _zone), do: nil

  # ── A job ───────────────────────────────────────────────────────────────────

  @doc """
  What the sweeps do to a job at `now`: `:archive` (no unarchived lead, and
  quiet `inactivity_days` by its own `last_activity_at`), `:purge` (archived
  `purge_after_days` with no lead at all) or `:none`. `live_leads` counts
  its unarchived leads, `leads` all of them.
  """
  @spec job_action(map(), non_neg_integer(), non_neg_integer(), settings(), DateTime.t()) ::
          :archive | :purge | :none
  def job_action(job, live_leads, leads, settings, %DateTime{} = now) do
    cond do
      is_nil(job.archived_at) and live_leads == 0 and
          reached?(job_archive_at(job, settings), now) ->
        :archive

      not is_nil(job.archived_at) and leads == 0 and
          reached?(add_days(job.archived_at, settings.purge_after_days), now) ->
        :purge

      true ->
        :none
    end
  end

  @doc "When the job went quiet: its `last_activity_at`, else when it was first seen."
  @spec job_quiet_since(map()) :: DateTime.t()
  def job_quiet_since(job), do: job.last_activity_at || job.first_seen_at || job.inserted_at

  @doc "When a live job archives, if no lead keeps it."
  @spec job_archive_at(map(), settings()) :: DateTime.t()
  def job_archive_at(job, settings), do: add_days(job_quiet_since(job), settings.inactivity_days)

  @doc "When an archived job purges, if no lead is left."
  @spec job_purge_at(map(), settings()) :: DateTime.t() | nil
  def job_purge_at(%{archived_at: %DateTime{} = at}, settings),
    do: add_days(at, settings.purge_after_days)

  def job_purge_at(_job, _settings), do: nil

  # ── Helpers ─────────────────────────────────────────────────────────────────

  @doc "Whether `at` has come by `now`."
  @spec reached?(DateTime.t(), DateTime.t()) :: boolean()
  def reached?(%DateTime{} = at, %DateTime{} = now), do: not DateTime.after?(at, now)

  @doc "The day of `at` in `zone`."
  @spec day(DateTime.t(), String.t()) :: Date.t()
  def day(%DateTime{} = at, zone) do
    case DateTime.shift_zone(at, zone) do
      {:ok, local} -> DateTime.to_date(local)
      _unknown -> DateTime.to_date(at)
    end
  end

  @doc "The first instant of `day` in `zone`, in UTC."
  @spec start_of(Date.t(), String.t()) :: DateTime.t()
  def start_of(%Date{} = day, zone) do
    case DateTime.new(day, ~T[00:00:00.000000], zone) do
      {:ok, at} -> DateTime.shift_zone!(at, "Etc/UTC")
      {:gap, _before, at} -> DateTime.shift_zone!(at, "Etc/UTC")
      {:ambiguous, at, _later} -> DateTime.shift_zone!(at, "Etc/UTC")
      {:error, _reason} -> DateTime.new!(day, ~T[00:00:00.000000])
    end
  end

  defp add_days(at, days), do: DateTime.add(at, days * @day, :second)
end
