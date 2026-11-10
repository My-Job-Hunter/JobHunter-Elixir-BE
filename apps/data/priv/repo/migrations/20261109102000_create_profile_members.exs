defmodule Data.Repo.Migrations.CreateProfileMembers do
  use Ecto.Migration

  @moduledoc """
  The owners of a profile (JH-01 §4.3; PLAN §3.2): the staff who hunt for
  it. The pair is unique; `since_on` is the day they took it on. The portal's
  "who serves me" reads these names when the team allows it.
  """

  def change do
    create table(:profile_members, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:profile_id, references(:profiles, type: :uuid, on_delete: :delete_all), null: false)
      add(:user_id, references(:users, type: :uuid, on_delete: :delete_all), null: false)
      add(:since_on, :date, null: false)
    end

    create(unique_index(:profile_members, [:profile_id, :user_id]))
    create(index(:profile_members, [:user_id]))
  end
end
