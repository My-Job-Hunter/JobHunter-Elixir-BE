defmodule Core.Jobs.CaptureTest do
  @moduledoc "AQ-05 §10.2, QP5-14: a signals row only when a fact changed; a snapshot once per text."

  use Core.CoreCase, async: true

  alias Core.Jobs.Capture
  alias Data.JobParts

  doctest Capture

  @now ~U[2026-11-11 09:00:00.000000Z]

  setup do
    c = board_cast_fixture()
    scope = %{scope_for(c.fiza) | via: :extension}

    job =
      job_fixture(scope, team: c.backend, url: "https://www.upwork.com/jobs/~0123456789abcdef")

    Map.merge(c, %{scope: scope, job: job})
  end

  defp capture(signal, body \\ ~s({"title":"Go"})),
    do: %{snapshot: %{body: body, captured_at: @now}, signal: signal}

  test "the first capture keeps a snapshot and a signals row", c do
    assert {:ok, %{snapshot: true, signal: true}} =
             Capture.write(c.scope, c.job, capture(%{proposals_min: 10, proposals_max: 15}), @now)

    assert [%{content_type: :fields, origin: :extension}] =
             Data.Repo.preload(c.job, :snapshots).snapshots

    assert %{proposals_min: 10, proposals_max: 15} = JobParts.latest_signal(c.job.id)
  end

  test "the same page again adds nothing; a number that moved adds one row", c do
    signal = %{proposals_min: 10, proposals_max: 15}
    {:ok, _} = Capture.write(c.scope, c.job, capture(signal), @now)

    assert {:ok, %{snapshot: false, signal: false}} =
             Capture.write(c.scope, c.job, capture(signal), @now)

    assert {:ok, %{signal: true}} =
             Capture.write(c.scope, c.job, capture(%{proposals_min: 15, proposals_max: 20}), @now)

    assert JobParts.signal_count(c.job.id) == 2
  end

  test "the client looked again only when the moment moved past its precision", c do
    viewed = %{client_last_viewed_at: ~U[2026-11-11 07:00:00.000000Z], slack_s: 3600}
    {:ok, %{signal: true}} = Capture.write(c.scope, c.job, capture(viewed), @now)

    # "3 hours ago", an hour later: the same moment.
    same = %{viewed | client_last_viewed_at: ~U[2026-11-11 07:20:00.000000Z]}
    assert {:ok, %{signal: false}} = Capture.write(c.scope, c.job, capture(same), @now)

    # "5 minutes ago": the client looked again.
    again = %{client_last_viewed_at: ~U[2026-11-11 09:55:00.000000Z], slack_s: 60}
    assert {:ok, %{signal: true}} = Capture.write(c.scope, c.job, capture(again), @now)
  end

  test "numbers the row refuses are no signal, and refuse nothing else", c do
    bad = %{proposals_min: 20, proposals_max: 5}

    assert {:ok, %{snapshot: true, signal: false}} =
             Capture.write(c.scope, c.job, capture(bad), @now)

    assert JobParts.signal_count(c.job.id) == 0
  end

  test "no capture, nothing written", c do
    assert Capture.write(c.scope, c.job, nil, @now) == {:ok, %{snapshot: false, signal: false}}
  end
end
