defmodule Core.Jobs.Capture do
  @moduledoc """
  What a capture by the extension leaves on a job besides its columns
  (AQ-05 §10.1, §10.2), **one rule, one home**, for a new job
  (`Core.Jobs.insert_new/5`) and a pool job seen again
  (`Core.Ingest.Extension`):

  - **the snapshot** of kind `fields` — the adapter's raw fields as JSON
    text, deduped by its hash (P3's index), so the same page twice is one
    snapshot and a parser fix can re-read old captures;
  - **a signals row** (`job_signals`) **only when a fact differs from the
    job's latest row** (QP5-14): a fact the page did not show is no
    change, and `client_last_viewed_at` — "2 hours ago", read again an
    hour later — is the same moment within the precision it was read at.

  Runs inside the caller's transaction. A capture is `%{snapshot: %{body,
  captured_at}, signal: %{facts…, slack_s} | nil}`, as
  `Core.Ingest.Extension.Normalize` makes it.
  """

  alias Data.JobParts
  alias Data.Jobs.Signal
  alias Data.Scope

  @doc """
  Writes the snapshot and the signals row the capture calls for. Answers
  `{:ok, %{snapshot: boolean, signal: boolean}}` — whether each was new.
  """
  @spec write(Scope.t(), map(), map() | nil, DateTime.t(), keyword()) :: {:ok, map()}
  def write(scope, job, capture, now, opts \\ [])

  def write(_scope, _job, nil, _now, _opts), do: {:ok, %{snapshot: false, signal: false}}

  def write(%Scope{} = scope, job, capture, %DateTime{} = now, opts) do
    {:ok, snapshot?} =
      if Keyword.get(opts, :snapshot, true),
        do: snapshot(scope, job, capture[:snapshot], now),
        else: {:ok, false}

    {:ok, signal?} = signal(scope, job, capture[:signal], now)
    {:ok, %{snapshot: snapshot?, signal: signal?}}
  end

  defp snapshot(_scope, _job, nil, _now), do: {:ok, false}

  defp snapshot(scope, job, %{body: body} = snap, now) do
    attrs = %{
      job_id: job.id,
      captured_at: snap[:captured_at] || now,
      captured_by_user_id: Scope.user_id(scope),
      origin: :extension,
      content_type: :fields,
      body: body
    }

    # A body the table refuses (too long) is not kept, and costs the
    # capture nothing else.
    case JobParts.add_snapshot(attrs) do
      {:ok, :exists} -> {:ok, false}
      {:ok, _snapshot} -> {:ok, true}
      {:error, %Ecto.Changeset{}} -> {:ok, false}
    end
  end

  defp signal(_scope, _job, nil, _now), do: {:ok, false}

  defp signal(scope, job, signal, now) do
    {slack, facts} = Map.pop(signal, :slack_s, 0)
    facts = Map.take(facts, Signal.facts())

    if changed?(facts, JobParts.latest_signal(job.id), slack) do
      attrs =
        Map.merge(facts, %{
          organisation_id: job.organisation_id,
          job_id: job.id,
          observed_at: now,
          observed_by_user_id: Scope.user_id(scope)
        })

      # Numbers the row refuses (out of range) are no signal at all.
      case JobParts.add_signal(attrs) do
        {:ok, _row} -> {:ok, true}
        {:error, %Ecto.Changeset{}} -> {:ok, false}
      end
    else
      {:ok, false}
    end
  end

  @doc """
  Whether `facts` (what this capture read; `nil` is "not shown") differ from
  the `latest` row, `client_last_viewed_at` compared within `slack_s`
  seconds. Pure. With no fact read, nothing changed; with no row yet, any
  fact is a change.

      iex> Core.Jobs.Capture.changed?(%{proposals_min: 10, proposals_max: 15}, nil, 0)
      true
      iex> Core.Jobs.Capture.changed?(%{proposals_min: 10}, %{proposals_min: 10, hires: 1}, 0)
      false
      iex> Core.Jobs.Capture.changed?(%{}, nil, 0)
      false
  """
  @spec changed?(map(), map() | nil, non_neg_integer()) :: boolean()
  def changed?(facts, latest, slack_s) do
    read = for {k, v} <- facts, not is_nil(v), do: {k, v}

    cond do
      read == [] -> false
      is_nil(latest) -> true
      true -> Enum.any?(read, fn {k, v} -> differs?(k, v, Map.get(latest, k), slack_s) end)
    end
  end

  defp differs?(:client_last_viewed_at, %DateTime{} = new, %DateTime{} = old, slack_s),
    do: abs(DateTime.diff(new, old, :second)) > slack_s

  defp differs?(_key, new, old, _slack_s), do: new != old
end
