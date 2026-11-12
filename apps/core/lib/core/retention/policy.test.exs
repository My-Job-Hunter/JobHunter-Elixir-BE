defmodule Core.Retention.PolicyTest do
  @moduledoc """
  AQ-04B §7.1, the pure rule, case by case: the quiet clock with the hold's
  *until* day, pinned exempt (Hired pins itself), the warning at 83 days
  once per quiet spell, the archive at 90, the purge 90 days after the
  archive, a job with and without a live lead, and the card's warning from
  60 days.
  """

  use ExUnit.Case, async: true

  alias Core.Retention.Policy

  @settings %{inactivity_days: 90, warning_days: 7, purge_after_days: 90}
  @t0 ~U[2026-11-01 09:00:00.000000Z]
  @utc "Etc/UTC"

  defp day(n), do: DateTime.add(@t0, n * 86_400, :second)

  defp lead(attrs \\ %{}) do
    Map.merge(
      %{
        last_activity_at: @t0,
        state: :in_progress,
        hold_until_on: nil,
        is_pinned: false,
        archived_at: nil
      },
      Map.new(attrs)
    )
  end

  defp action(lead, now, warned_at \\ nil),
    do: Policy.lead_action(lead, warned_at, @settings, now, @utc)

  test "the table: nothing, the warning at 83, the archive at 90" do
    assert action(lead(), day(82)) == :none
    assert action(lead(), day(83)) == :warn
    assert action(lead(), day(89)) == :warn
    assert action(lead(), day(90)) == :archive
  end

  test "warned once per quiet spell: a touch after the warning earns a fresh one 83 days on" do
    assert action(lead(), day(84), day(83)) == :none

    touched = lead(last_activity_at: day(85))
    assert action(touched, day(100), day(83)) == :none
    assert action(touched, day(168), day(83)) == :warn
  end

  test "pinned leads are exempt from every step, archived or not" do
    assert action(lead(is_pinned: true), day(500)) == :none
    assert action(lead(is_pinned: true, archived_at: day(90)), day(500)) == :none
  end

  test "the hired lead (pinned by Hired) never archives" do
    assert action(lead(state: :done, is_pinned: true), day(200)) == :none
  end

  test "a held lead waits for its until day: the clock starts at the end of that day" do
    held = lead(state: :on_hold, hold_until_on: ~D[2026-12-01])

    assert Policy.quiet_since(held, @utc) == ~U[2026-12-02 00:00:00.000000Z]
    assert action(held, day(90)) == :none
    assert action(held, ~U[2027-03-02 00:00:00.000000Z]) == :archive
  end

  test "the hold's day ends in the organisation's zone" do
    held = lead(state: :on_hold, hold_until_on: ~D[2026-12-01])
    assert Policy.quiet_since(held, "Asia/Karachi") == ~U[2026-12-01 19:00:00.000000Z]
  end

  test "an until day earlier than the last activity changes nothing" do
    held = lead(state: :on_hold, hold_until_on: ~D[2026-10-01])
    assert Policy.quiet_since(held, @utc) == @t0
  end

  test "an archived lead is past the warning and the archive; it purges 90 days on" do
    archived = lead(archived_at: day(90))

    assert action(archived, day(179)) == :none
    assert action(archived, day(180)) == :purge
  end

  test "the card: archives_on always for a live lead, the warning from 60 quiet days" do
    assert %{archives_on: ~D[2027-01-30], warn: false} =
             Policy.quiet(lead(), @settings, day(59), @utc)

    assert %{archives_on: ~D[2027-01-30], warn: true, since: @t0} =
             Policy.quiet(lead(), @settings, day(60), @utc)

    assert %{archives_on: nil, warn: false} =
             Policy.quiet(lead(is_pinned: true), @settings, day(80), @utc)

    assert %{archives_on: nil, warn: false, purges_on: ~D[2027-04-30]} =
             Policy.quiet(lead(archived_at: day(90)), @settings, day(95), @utc)
  end

  test "a job: never archived with a live lead; archived quiet with none; purged bare" do
    job = %{last_activity_at: @t0, first_seen_at: @t0, inserted_at: @t0, archived_at: nil}

    assert Policy.job_action(job, 1, 1, @settings, day(400)) == :none
    assert Policy.job_action(job, 0, 2, @settings, day(89)) == :none
    assert Policy.job_action(job, 0, 2, @settings, day(90)) == :archive

    archived = %{job | archived_at: day(90)}
    assert Policy.job_action(archived, 0, 1, @settings, day(400)) == :none
    assert Policy.job_action(archived, 0, 0, @settings, day(179)) == :none
    assert Policy.job_action(archived, 0, 0, @settings, day(180)) == :purge
  end

  test "a job nobody touched is quiet from when it was first seen" do
    job = %{last_activity_at: nil, first_seen_at: @t0, inserted_at: day(5), archived_at: nil}
    assert Policy.job_quiet_since(job) == @t0
  end
end
