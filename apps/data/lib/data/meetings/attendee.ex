defmodule Data.Meetings.Attendee do
  @moduledoc "Who is in a meeting (AQ-06 §5.3, QP6-14): a staff user, a contact or the customer — one of three."

  use Data.Schema

  alias Data.Accounts.User
  alias Data.Contacts.Contact
  alias Data.Meetings.Meeting

  @type t :: %__MODULE__{}

  schema "meeting_attendees" do
    field(:is_customer, :boolean, default: false)

    belongs_to(:meeting, Meeting)
    belongs_to(:user, User)
    belongs_to(:contact, Contact)
  end

  def changeset(attendee, attrs) do
    attendee
    |> cast(attrs, [:meeting_id, :user_id, :contact_id, :is_customer])
    |> validate_required([:meeting_id])
    |> check_constraint(:user_id, name: :one_attendee, message: "is one person")
    |> unique_constraint(:user_id, name: :meeting_attendees_user_index, message: "is in already")
    |> unique_constraint(:contact_id,
      name: :meeting_attendees_contact_index,
      message: "is in already"
    )
    |> unique_constraint(:is_customer,
      name: :meeting_attendees_customer_index,
      message: "is in already"
    )
    |> foreign_key_constraint(:contact_id)
    |> foreign_key_constraint(:user_id)
  end
end
