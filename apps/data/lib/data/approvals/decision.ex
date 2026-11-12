defmodule Data.Approvals.Decision do
  @moduledoc """
  What one slot said of one version (AQ-07 §5.2, QP7-6): approved, changes
  requested or rejected, with a note for the last two; who took the slot
  (none when the system approved it, §9). One per slot per version.
  """

  use Data.Schema

  alias Data.Accounts.User
  alias Data.Approvals.{Approval, Reviewer}
  alias Data.Vocabulary

  @decisions Vocabulary.approval_decisions() |> Enum.map(&String.to_atom/1)

  @type t :: %__MODULE__{}

  schema "approval_decisions" do
    field(:version_number, :integer)
    field(:decision, Ecto.Enum, values: @decisions)
    field(:note, :string)
    field(:decided_at, :utc_datetime_usec)

    belongs_to(:approval, Approval)
    belongs_to(:approval_reviewer, Reviewer)
    belongs_to(:decided_by_user, User)
  end

  def changeset(decision, attrs) do
    decision
    |> cast(attrs, [
      :approval_id,
      :approval_reviewer_id,
      :version_number,
      :decision,
      :note,
      :decided_by_user_id,
      :decided_at
    ])
    |> validate_required([
      :approval_id,
      :approval_reviewer_id,
      :version_number,
      :decision,
      :decided_at
    ])
    |> validate_length(:note, max: 2000)
    |> check_constraint(:decision, name: :decision_known)
    |> check_constraint(:note, name: :note_with_refusal, message: "is required")
    |> check_constraint(:note, name: :note_length, message: "is too long")
    |> unique_constraint(:approval_reviewer_id,
      name: :approval_decisions_approval_reviewer_id_version_number_index,
      message: "has decided this version"
    )
  end
end
