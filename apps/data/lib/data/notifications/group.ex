defmodule Data.Notifications.Group do
  @moduledoc "What a notification is about (AQ-02 §5.2): the chips, and in P8 the preferences."

  use Data.Schema

  @primary_key {:key, :string, autogenerate: false}

  @type t :: %__MODULE__{}

  schema "notification_groups" do
    field(:label, :string)
    field(:position, :integer, default: 0)
    field(:can_disable, :boolean, default: true)
  end

  def changeset(group, attrs) do
    group
    |> cast(attrs, [:key, :label, :position, :can_disable])
    |> validate_required([:key, :label])
    |> check_constraint(:key, name: :key_shape)
  end
end
