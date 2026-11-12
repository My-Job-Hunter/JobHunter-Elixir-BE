defmodule Data.Repo.Migrations.CreateMeetingAttendees do
  use Ecto.Migration

  @moduledoc """
  Who is in a meeting (AQ-06 §5.3, QP6-14): **one of three** — a staff
  user, a contact, or the customer (the lead's) — held by a CHECK, never a
  polymorphic pair (PLAN §16). Each attendee once. Reminders go to the
  customer, the lead's owner and the staff attendees.
  """

  def change do
    create table(:meeting_attendees, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(:meeting_id, references(:meetings, type: :uuid, on_delete: :delete_all), null: false)
      add(:user_id, references(:users, type: :uuid, on_delete: :delete_all))
      add(:contact_id, references(:contacts, type: :uuid, on_delete: :delete_all))
      add(:is_customer, :boolean, null: false, default: false)
    end

    create(
      constraint(:meeting_attendees, :one_attendee,
        check: "num_nonnulls(user_id, contact_id) + (CASE WHEN is_customer THEN 1 ELSE 0 END) = 1"
      )
    )

    create(
      unique_index(:meeting_attendees, [:meeting_id, :user_id],
        where: "user_id IS NOT NULL",
        name: :meeting_attendees_user_index
      )
    )

    create(
      unique_index(:meeting_attendees, [:meeting_id, :contact_id],
        where: "contact_id IS NOT NULL",
        name: :meeting_attendees_contact_index
      )
    )

    create(
      unique_index(:meeting_attendees, [:meeting_id],
        where: "is_customer",
        name: :meeting_attendees_customer_index
      )
    )

    create(index(:meeting_attendees, [:meeting_id]))
    create(index(:meeting_attendees, [:user_id]))
    create(index(:meeting_attendees, [:contact_id]))
  end
end
