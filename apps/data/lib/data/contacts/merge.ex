defmodule Data.Contacts.Merge do
  @moduledoc """
  A merged contact's name and handles (AQ-06 §6, QP6-4), P3's `job_merges`
  pattern: what the merged contact was, pointing at its survivor.
  """

  use Data.Schema

  alias Data.Accounts.User
  alias Data.Contacts.Contact
  alias Data.Organisations.Organisation

  @type t :: %__MODULE__{}

  schema "contact_merges" do
    field(:from_name, :string)
    field(:from_handles, {:array, :string}, default: [])
    field(:merged_at, :utc_datetime_usec)

    belongs_to(:organisation, Organisation)
    belongs_to(:into_contact, Contact)
    belongs_to(:merged_by_user, User)
  end

  def changeset(merge, attrs) do
    merge
    |> cast(attrs, [
      :organisation_id,
      :into_contact_id,
      :from_name,
      :from_handles,
      :merged_by_user_id,
      :merged_at
    ])
    |> validate_required([:organisation_id, :into_contact_id, :from_name, :merged_at])
    |> foreign_key_constraint(:into_contact_id)
  end
end
