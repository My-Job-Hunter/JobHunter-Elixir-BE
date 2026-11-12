defmodule Data.Leads.Fingerprint do
  @moduledoc """
  A purged lead's tombstone (AQ-04B §5.2, §7.2): the posting's key, the
  profile and its customer, the day it was applied, the engine stage kinds
  it reached, its outcome. Written by the purge before the lead goes; read
  by `Core.Leads.Guard`.
  """

  use Data.Schema

  alias Data.Customers.{Customer, Profile}
  alias Data.Organisations.Organisation
  alias Data.Teams.Team
  alias Data.Vocabulary

  @kinds Vocabulary.stage_kinds() |> Enum.map(&String.to_atom/1)
  @outcomes Vocabulary.lead_outcomes() |> Enum.map(&String.to_atom/1)

  @type t :: %__MODULE__{}

  schema "lead_fingerprints" do
    field(:canonical_key, :string)
    field(:applied_on, :date)
    field(:stage_kinds, {:array, Ecto.Enum}, values: @kinds, default: [])
    field(:outcome, Ecto.Enum, values: @outcomes)
    field(:purged_at, :utc_datetime_usec)

    belongs_to(:organisation, Organisation)
    belongs_to(:team, Team)
    belongs_to(:profile, Profile)
    belongs_to(:customer, Customer)
  end

  def changeset(fingerprint, attrs) do
    fingerprint
    |> cast(attrs, [
      :organisation_id,
      :team_id,
      :canonical_key,
      :profile_id,
      :customer_id,
      :applied_on,
      :stage_kinds,
      :outcome,
      :purged_at
    ])
    |> validate_required([
      :organisation_id,
      :canonical_key,
      :profile_id,
      :customer_id,
      :purged_at
    ])
    |> check_constraint(:stage_kinds, name: :stage_kinds_known)
    |> check_constraint(:outcome, name: :outcome_known)
  end
end
