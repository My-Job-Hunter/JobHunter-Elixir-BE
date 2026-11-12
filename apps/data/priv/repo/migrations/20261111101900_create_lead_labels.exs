defmodule Data.Repo.Migrations.CreateLeadLabels do
  use Ecto.Migration

  @moduledoc """
  Which labels a lead wears (AQ-04B §5.1): a pair, gone with either side
  (a purged lead, a removed label).
  """

  def change do
    create table(:lead_labels, primary_key: false) do
      add(:lead_id, references(:leads, type: :uuid, on_delete: :delete_all), primary_key: true)

      add(:label_id, references(:labels, type: :uuid, on_delete: :delete_all), primary_key: true)
    end

    create(index(:lead_labels, [:label_id]))
  end
end
