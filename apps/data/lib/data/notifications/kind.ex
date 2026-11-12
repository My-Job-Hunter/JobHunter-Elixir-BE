defmodule Data.Notifications.Kind do
  @moduledoc "An event that raises a notification (AQ-02 §5.2, §8), with its default channels."

  use Data.Schema

  alias Data.Notifications.Group

  @primary_key {:key, :string, autogenerate: false}

  @type t :: %__MODULE__{}

  schema "notification_kinds" do
    field(:default_channels, {:array, :string}, default: ["inapp"])
    field(:can_ignore_quiet_hours, :boolean, default: false)

    belongs_to(:notification_group, Group,
      foreign_key: :notification_group_key,
      references: :key,
      type: :string
    )
  end

  def changeset(kind, attrs) do
    kind
    |> cast(attrs, [:key, :notification_group_key, :default_channels, :can_ignore_quiet_hours])
    |> validate_required([:key, :notification_group_key, :default_channels])
    |> check_constraint(:key, name: :key_names_its_group)
    |> check_constraint(:default_channels, name: :default_channels_known)
    |> foreign_key_constraint(:notification_group_key)
  end
end
