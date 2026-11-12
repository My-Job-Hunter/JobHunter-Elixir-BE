defmodule Data.Repo.Migrations.CreateProfileChannels do
  use Ecto.Migration

  @moduledoc """
  Which channels a profile works through (AQ-01 §4.3; PLAN §4). A channel
  belongs to the customer; this links it to the profiles that use it. Both
  sides going takes the link with them.
  """

  def change do
    create table(:profile_channels, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:profile_id, references(:profiles, type: :uuid, on_delete: :delete_all), null: false)
      add(:channel_id, references(:channels, type: :uuid, on_delete: :delete_all), null: false)
    end

    create(unique_index(:profile_channels, [:profile_id, :channel_id]))
    create(index(:profile_channels, [:channel_id]))
  end
end
