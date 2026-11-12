defmodule Data.Leads.Note do
  @moduledoc """
  A note on a lead (AQ-04B §5.1, QP4b-13): markdown, staff only, its
  author's or a team lead's to edit or delete (`Core.Access.Leads`).
  """

  use Data.Schema

  alias Data.Accounts.User
  alias Data.Leads.Lead
  alias Data.Organisations.Organisation

  @type t :: %__MODULE__{}

  schema "lead_notes" do
    field(:body_md, :string)

    belongs_to(:organisation, Organisation)
    belongs_to(:lead, Lead)
    belongs_to(:author_user, User)

    timestamps()
  end

  @doc "A new note: its lead, its author and its body."
  def create_changeset(note, attrs) do
    note
    |> cast(attrs, [:organisation_id, :lead_id, :author_user_id, :body_md])
    |> validate_required([:organisation_id, :lead_id])
    |> body()
  end

  @doc "An edit: the body alone."
  def changeset(note, attrs), do: note |> cast(attrs, [:body_md]) |> body()

  defp body(changeset) do
    changeset
    |> update_change(:body_md, &String.trim/1)
    |> validate_required([:body_md])
    |> validate_length(:body_md, max: 10_000)
    |> check_constraint(:body_md, name: :body_present, message: "can't be blank")
  end
end
