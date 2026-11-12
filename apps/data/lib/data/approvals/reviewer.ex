defmodule Data.Approvals.Reviewer do
  @moduledoc """
  A reviewer slot (AQ-07 §5.2, QP7-4): `customer`, `team_lead` (any lead of
  the team takes it) or `user` (a named person, `user_id`). Its decisions,
  one per version, are `approval_decisions`.
  """

  use Data.Schema

  alias Data.Accounts.User
  alias Data.Approvals.Approval
  alias Data.Vocabulary

  @slots Vocabulary.reviewer_slots() |> Enum.map(&String.to_atom/1)

  @type t :: %__MODULE__{}

  schema "approval_reviewers" do
    field(:slot, Ecto.Enum, values: @slots)
    field(:position, :integer, default: 0)

    belongs_to(:approval, Approval)
    belongs_to(:user, User)
  end

  def changeset(reviewer, attrs) do
    reviewer
    |> cast(attrs, [:approval_id, :slot, :user_id, :position])
    |> validate_required([:approval_id, :slot])
    |> check_constraint(:slot, name: :slot_known)
    |> check_constraint(:user_id, name: :user_for_user_slot, message: "names the slot's person")
    |> unique_constraint(:slot, name: :approval_reviewers_slot_index, message: "is there already")
    |> foreign_key_constraint(:user_id)
  end
end
