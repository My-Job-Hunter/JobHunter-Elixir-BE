defmodule Core.Approvals.Rule do
  @moduledoc """
  The outcome of an approval's version (AQ-07 §6, QP7-5), **pure**: the
  slots and that version's decisions in, the outcome out.

  1. any `rejected` → **rejected**;
  2. else any `changes_requested` → **changes_requested**;
  3. else *any*: one `approved` → **approved**; *all*: every slot
     `approved` → **approved**;
  4. else still **pending**.

  A slot is *open* on a version while the approval is pending and the slot
  has no decision on it; a revision opens every slot again (QP7-6), since
  its decisions are on the new number.
  """

  @type outcome :: :approved | :changes_requested | :rejected | :pending

  @doc """
  The outcome under `rule` (`:any` or `:all`) of `slots` (each with `id`)
  and `decisions` (each with `approval_reviewer_id` and `decision`) — the
  decisions of one version.
  """
  @spec outcome(:any | :all, [map()], [map()]) :: outcome()
  def outcome(rule, slots, decisions) do
    said = Enum.map(decisions, & &1.decision)

    cond do
      :rejected in said -> :rejected
      :changes_requested in said -> :changes_requested
      approved?(rule, slots, decisions) -> :approved
      true -> :pending
    end
  end

  defp approved?(:any, _slots, decisions), do: Enum.any?(decisions, &(&1.decision == :approved))

  defp approved?(:all, [], _decisions), do: false

  defp approved?(:all, slots, decisions) do
    yes =
      for d <- decisions, d.decision == :approved, into: MapSet.new(), do: d.approval_reviewer_id

    Enum.all?(slots, &MapSet.member?(yes, &1.id))
  end

  @doc "The slots with no decision among `decisions` (one version's)."
  @spec open([map()], [map()]) :: [map()]
  def open(slots, decisions) do
    said = MapSet.new(decisions, & &1.approval_reviewer_id)
    Enum.reject(slots, &MapSet.member?(said, &1.id))
  end
end
