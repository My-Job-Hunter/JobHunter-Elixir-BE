defmodule Data.Repo.Migrations.CreateLeadContacts do
  use Ecto.Migration

  @moduledoc """
  The people on a lead (AQ-06 §5.1): a contact linked to a lead in a role
  (`recruiter · hiring_manager · interviewer · client · referrer ·
  other`) — the lead page's **Recruiters** tab, your brief's "link multiple
  recruiters to that particular lead". One link per (lead, contact); each
  link and unlink writes `contact_linked` / `contact_unlinked` (staff). A
  purged lead takes its links; the contact stays (it is the organisation's).
  """

  @roles ~w(recruiter hiring_manager interviewer client referrer other)

  def change do
    create table(:lead_contacts, primary_key: false) do
      add(:lead_id, references(:leads, type: :uuid, on_delete: :delete_all), primary_key: true)

      add(:contact_id, references(:contacts, type: :uuid, on_delete: :delete_all),
        primary_key: true
      )

      add(:role, :text, null: false)
      add(:linked_by_user_id, references(:users, type: :uuid, on_delete: :nilify_all))
      add(:inserted_at, :timestamptz, null: false, default: fragment("now()"))
    end

    create(constraint(:lead_contacts, :role_known, check: "role IN (#{list(@roles)})"))
    create(index(:lead_contacts, [:contact_id]))
    create(index(:lead_contacts, [:linked_by_user_id]))
  end

  defp list(values), do: Enum.map_join(values, ",", &"'#{&1}'")
end
