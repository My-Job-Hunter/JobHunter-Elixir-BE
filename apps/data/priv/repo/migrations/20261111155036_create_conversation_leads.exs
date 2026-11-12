defmodule Data.Repo.Migrations.CreateConversationLeads do
  use Ecto.Migration

  @moduledoc """
  Which leads a conversation is about (AQ-06 §5.2, §7.2, QP6-10). **A
  conversation links only to leads of its own team** (`Core.Conversations`
  holds it). Every link says how it was made (`match_method`: `by_hand ·
  headers · thread_id · sender_handle · created_from_triage`) and how sure
  (`sure` for headers and a thread id, `likely` for one open lead of the
  sender's handle), so a likely link is visible and undoable from the lead.
  A purged lead takes its links; a conversation only it held goes with it
  (AQ-06 §10).
  """

  @methods ~w(by_hand headers thread_id sender_handle created_from_triage)

  def change do
    create table(:conversation_leads, primary_key: false) do
      add(:conversation_id, references(:conversations, type: :uuid, on_delete: :delete_all),
        primary_key: true
      )

      add(:lead_id, references(:leads, type: :uuid, on_delete: :delete_all), primary_key: true)
      add(:match_method, :text, null: false)
      add(:confidence, :text, null: false)
      add(:linked_by_user_id, references(:users, type: :uuid, on_delete: :nilify_all))
      add(:inserted_at, :timestamptz, null: false, default: fragment("now()"))
    end

    create(
      constraint(:conversation_leads, :match_method_known,
        check: "match_method IN (#{list(@methods)})"
      )
    )

    create(
      constraint(:conversation_leads, :confidence_known, check: "confidence IN ('sure','likely')")
    )

    create(index(:conversation_leads, [:lead_id]))
    create(index(:conversation_leads, [:linked_by_user_id]))
  end

  defp list(values), do: Enum.map_join(values, ",", &"'#{&1}'")
end
