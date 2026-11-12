defmodule Data.Repo.Migrations.CreateSavedViews do
  use Ecto.Migration

  @moduledoc """
  A person's saved views (AQ-04B §5.1, §9, QP4b-16): one table for the
  Tracker, both lead boards, Jobs and the task board. A view keeps the
  URL's query **without the team** (so it works in every team) and, for the
  Tracker, its chosen columns in order. Their owner's alone; their names
  unique per person and screen, whatever the case.
  """

  @screens ~w(tracker leads jobs board)
  @columns ~w(applied title company source customer profile owner state outcome next
              last_activity money workplace engagement cv labels missing)

  def change do
    create table(:saved_views, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(:organisation_id, references(:organisations, type: :uuid, on_delete: :delete_all),
        null: false
      )

      add(:user_id, references(:users, type: :uuid, on_delete: :delete_all), null: false)
      add(:screen, :text, null: false)
      add(:name, :text, null: false)
      add(:query, :text, null: false, default: "")
      add(:columns, {:array, :text}, null: false, default: [])
      add(:position, :smallint, null: false, default: 0)

      timestamps()
    end

    create(constraint(:saved_views, :screen_known, check: "screen IN (#{list(@screens)})"))

    create(
      constraint(:saved_views, :name_present,
        check: "btrim(name) <> '' AND char_length(name) <= 60"
      )
    )

    create(
      constraint(:saved_views, :columns_known,
        check: "columns <@ ARRAY[#{list(@columns)}]::text[]"
      )
    )

    create(constraint(:saved_views, :query_length, check: "char_length(query) <= 4000"))

    create(
      unique_index(:saved_views, [:user_id, :screen, "lower(name)"],
        name: :saved_views_user_screen_name_index
      )
    )

    create(index(:saved_views, [:user_id]))
    create(index(:saved_views, [:organisation_id]))

    execute(
      "CREATE TRIGGER touch_updated_at BEFORE UPDATE ON saved_views " <>
        "FOR EACH ROW EXECUTE FUNCTION touch_updated_at()",
      "DROP TRIGGER IF EXISTS touch_updated_at ON saved_views"
    )
  end

  defp list(values), do: Enum.map_join(values, ",", &"'#{&1}'")
end
