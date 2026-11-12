defmodule Data.Repo.Migrations.CreatePushSubscriptions do
  use Ecto.Migration

  @moduledoc """
  A browser that takes Web Push for a person (AQ-08 §5, QP8-14; mCart's):
  the push service's endpoint and the browser's keys, the app it was made
  on (`push_apps`: `team` the console, `client` the portal), when it was
  last used and when it last failed.

  **The endpoint is unique**: the same browser signed in as someone else
  moves to them, so a shared computer never pushes one person's notices to
  the next. An endpoint the push service says is gone (404, 410) is
  deleted. A person's own, gone with the person (QP8-21).
  """

  @apps ~w(team client)

  def change do
    create table(:push_subscriptions, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:user_id, references(:users, type: :uuid, on_delete: :delete_all), null: false)
      add(:app, :text, null: false)
      add(:endpoint, :text, null: false)
      add(:p256dh, :text, null: false)
      add(:auth, :text, null: false)
      add(:user_agent, :string, size: 255)
      add(:last_used_at, :timestamptz)
      add(:failed_at, :timestamptz)

      timestamps()
    end

    create(constraint(:push_subscriptions, :app_known, check: "app IN (#{list(@apps)})"))

    create(constraint(:push_subscriptions, :endpoint_https, check: "endpoint ~ '^https://'"))

    create(constraint(:push_subscriptions, :keys_present, check: "p256dh <> '' AND auth <> ''"))
    create(unique_index(:push_subscriptions, [:endpoint]))
    create(index(:push_subscriptions, [:user_id]))

    execute(
      "CREATE TRIGGER touch_updated_at BEFORE UPDATE ON push_subscriptions " <>
        "FOR EACH ROW EXECUTE FUNCTION touch_updated_at()",
      "DROP TRIGGER IF EXISTS touch_updated_at ON push_subscriptions"
    )
  end

  defp list(values), do: Enum.map_join(values, ",", &"'#{&1}'")
end
