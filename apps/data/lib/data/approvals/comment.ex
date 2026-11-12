defmodule Data.Approvals.Comment do
  @moduledoc """
  A comment on an approval (AQ-07 §5.2, QP7-9): one stream, every party
  reads it. A deleted one keeps its place with no body.
  """

  use Data.Schema

  alias Data.Accounts.User
  alias Data.Approvals.Approval

  @type t :: %__MODULE__{}

  schema "approval_comments" do
    field(:body_md, :string, default: "")
    field(:deleted_at, :utc_datetime_usec)

    belongs_to(:approval, Approval)
    belongs_to(:author_user, User)

    timestamps()
  end

  def changeset(comment, attrs) do
    comment
    |> cast(attrs, [:approval_id, :author_user_id, :body_md])
    |> update_change(:body_md, &(&1 && String.trim(&1)))
    |> validate_required([:approval_id, :body_md])
    |> validate_length(:body_md, max: 5000)
    |> check_constraint(:body_md, name: :body_present, message: "can't be blank")
  end

  @doc "A tombstone: no body, its place kept."
  def delete_changeset(comment, %DateTime{} = at),
    do: change(comment, deleted_at: at, body_md: "")
end
