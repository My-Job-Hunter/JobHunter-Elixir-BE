defmodule Data.Repo.Migrations.CreateUsers do
  use Ecto.Migration

  @moduledoc """
  An account: a login for exactly one person (JH-01 §4.1).

  `email` is citext and unique: case-insensitive without every query
  remembering to downcase. `hashed_password` is null for an account made with
  Google until a reset sets one. A suspended or deactivated user cannot sign
  in, and every token is revoked on the change (QP1-10).

  `delete_at` and `purged_at` are the account-deletion stages, modelled now
  so the shape does not change when the flow arrives; nothing sets them in P1.
  """

  def change do
    create table(:users, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:person_id, references(:persons, type: :uuid, on_delete: :restrict), null: false)
      add(:email, :citext, null: false)
      add(:hashed_password, :string)
      add(:email_confirmed_at, :timestamptz)
      add(:welcomed_at, :timestamptz)
      add(:suspended_at, :timestamptz)
      add(:deactivated_at, :timestamptz)
      add(:delete_at, :timestamptz)
      add(:purged_at, :timestamptz)
      add(:last_signed_in_at, :timestamptz)

      timestamps()
    end

    create(unique_index(:users, [:email]))
    # One login per person, in P1.
    create(unique_index(:users, [:person_id]))

    execute(
      "CREATE TRIGGER touch_updated_at BEFORE UPDATE ON users " <>
        "FOR EACH ROW EXECUTE FUNCTION touch_updated_at()",
      "DROP TRIGGER IF EXISTS touch_updated_at ON users"
    )
  end
end
