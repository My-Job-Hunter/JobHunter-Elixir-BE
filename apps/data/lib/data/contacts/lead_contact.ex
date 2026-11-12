defmodule Data.Contacts.LeadContact do
  @moduledoc "A contact on a lead, in a role (AQ-06 §5.1): the Recruiters tab's row."

  use Data.Schema

  alias Data.Accounts.User
  alias Data.Contacts.Contact
  alias Data.Leads.Lead
  alias Data.Vocabulary

  @roles Vocabulary.contact_roles() |> Enum.map(&String.to_atom/1)

  @primary_key false

  @type t :: %__MODULE__{}

  schema "lead_contacts" do
    belongs_to(:lead, Lead, primary_key: true)
    belongs_to(:contact, Contact, primary_key: true)
    field(:role, Ecto.Enum, values: @roles)
    field(:inserted_at, :utc_datetime_usec, read_after_writes: true)

    belongs_to(:linked_by_user, User)
  end

  def changeset(link, attrs) do
    link
    |> cast(attrs, [:lead_id, :contact_id, :role, :linked_by_user_id])
    |> validate_required([:lead_id, :contact_id, :role])
    |> check_constraint(:role, name: :role_known)
    |> unique_constraint(:contact_id,
      name: :lead_contacts_pkey,
      message: "is on this lead already"
    )
    |> foreign_key_constraint(:contact_id)
  end
end
