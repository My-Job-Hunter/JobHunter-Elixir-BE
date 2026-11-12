defmodule Data.Repo.Migrations.CreateLeadFingerprints do
  use Ecto.Migration

  @moduledoc """
  The tombstone of a purged lead (AQ-04B §5.2, §7.2, QP4b-6): written by
  the purge **before** the lead is deleted, so the guard never forgets that
  this profile applied to this posting (Q7). It keeps the posting's key,
  the profile and its customer, the day it was applied, the engine stage
  kinds it reached in order, and its outcome — nothing a person wrote.
  The guard reads it by `(organisation_id, canonical_key, profile_id)`.
  """

  @kinds ~w(inbound applied seen screening assessment interview ai_interview final offer
            negotiation contract)
  @outcomes ~w(hired rejected withdrawn position_closed no_response not_pursued)

  def change do
    create table(:lead_fingerprints, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(:organisation_id, references(:organisations, type: :uuid, on_delete: :delete_all),
        null: false
      )

      add(:team_id, references(:teams, type: :uuid, on_delete: :nilify_all))
      add(:canonical_key, :text, null: false)
      add(:profile_id, references(:profiles, type: :uuid, on_delete: :delete_all), null: false)
      add(:customer_id, references(:customers, type: :uuid, on_delete: :delete_all), null: false)
      add(:applied_on, :date)
      add(:stage_kinds, {:array, :text}, null: false, default: [])
      add(:outcome, :text)
      add(:purged_at, :timestamptz, null: false)
    end

    create(
      constraint(:lead_fingerprints, :stage_kinds_known,
        check: "stage_kinds <@ ARRAY[#{list(@kinds)}]::text[]"
      )
    )

    create(
      constraint(:lead_fingerprints, :outcome_known,
        check: "outcome IS NULL OR outcome IN (#{list(@outcomes)})"
      )
    )

    create(
      index(:lead_fingerprints, [:organisation_id, :canonical_key, :profile_id],
        name: :lead_fingerprints_posting_index
      )
    )

    create(index(:lead_fingerprints, [:team_id]))
    create(index(:lead_fingerprints, [:profile_id]))
    create(index(:lead_fingerprints, [:customer_id]))
  end

  defp list(values), do: Enum.map_join(values, ",", &"'#{&1}'")
end
