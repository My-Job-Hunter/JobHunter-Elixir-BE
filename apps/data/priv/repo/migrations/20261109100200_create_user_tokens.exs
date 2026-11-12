defmodule Data.Repo.Migrations.CreateUserTokens do
  use Ecto.Migration

  @moduledoc """
  The one-time links an account is recovered and proved with (AQ-01 §4.1):
  reset a password, confirm an address, change an address.

  **A digest, never the token.** The plaintext exists once, in the mail; the
  row holds its SHA-256. A lookup by digest is also the comparison, so there
  is no timing to leak. `new_email` only for a change (CHECK). A reset lives
  an hour, a confirmation or change a day — the context's numbers.

  AQ-05 §5.4 (QP5-4): `connect_extension`, the one-time code the console
  hands the extension; two minutes, one use.
  """

  def change do
    create table(:user_tokens, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:user_id, references(:users, type: :uuid, on_delete: :delete_all), null: false)
      add(:purpose, :string, null: false)
      add(:token_digest, :string, null: false)
      add(:new_email, :citext)
      add(:expires_at, :timestamptz, null: false)
      add(:sent_at, :timestamptz)
      add(:used_at, :timestamptz)
      # For looking at afterwards, never for deciding anything.
      add(:requested_ip, :string)

      timestamps()
    end

    create(
      constraint(:user_tokens, :purpose_known,
        check: "purpose IN ('reset_password','confirm_email','change_email','connect_extension')"
      )
    )

    create(
      constraint(:user_tokens, :new_email_only_for_a_change,
        check: "(purpose = 'change_email') = (new_email IS NOT NULL)"
      )
    )

    create(unique_index(:user_tokens, [:purpose, :token_digest]))

    # "What is still outstanding for this account, for this purpose."
    create(
      index(:user_tokens, [:user_id, :purpose],
        where: "used_at IS NULL",
        name: :user_tokens_outstanding_index
      )
    )

    execute(
      "CREATE TRIGGER touch_updated_at BEFORE UPDATE ON user_tokens " <>
        "FOR EACH ROW EXECUTE FUNCTION touch_updated_at()",
      "DROP TRIGGER IF EXISTS touch_updated_at ON user_tokens"
    )
  end
end
