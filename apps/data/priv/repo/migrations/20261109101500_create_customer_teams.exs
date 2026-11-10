defmodule Data.Repo.Migrations.CreateCustomerTeams do
  use Ecto.Migration

  @moduledoc """
  Which teams serve a customer (JH-01 §4.3; PLAN Q27: several may). The
  pair is unique; `since_on` is the day the assignment began.
  """

  def change do
    create table(:customer_teams, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(:customer_id, references(:customers, type: :uuid, on_delete: :delete_all), null: false)

      add(:team_id, references(:teams, type: :uuid, on_delete: :delete_all), null: false)
      add(:since_on, :date, null: false)
    end

    create(unique_index(:customer_teams, [:customer_id, :team_id]))
    create(index(:customer_teams, [:team_id]))
  end
end
