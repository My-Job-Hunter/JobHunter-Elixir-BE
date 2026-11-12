defmodule Data.Repo.Migrations.CreateConversationParticipants do
  use Ecto.Migration

  @moduledoc """
  The contacts in a conversation (AQ-06 §5.2): the recruiter, the hiring
  manager, whoever wrote or was written to. **Staff and the customer are
  not rows**: they are the channel's side. A contact's page reads its
  conversations across platforms from here.
  """

  def change do
    create table(:conversation_participants, primary_key: false) do
      add(:conversation_id, references(:conversations, type: :uuid, on_delete: :delete_all),
        primary_key: true
      )

      add(:contact_id, references(:contacts, type: :uuid, on_delete: :delete_all),
        primary_key: true
      )
    end

    create(index(:conversation_participants, [:contact_id]))
  end
end
