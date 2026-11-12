defmodule Data.SavedViews.SavedView do
  @moduledoc """
  A person's saved view of a screen (AQ-04B §5.1, §9, QP4b-16): a name,
  the URL's query without the team, and the Tracker's columns in order.
  """

  use Data.Schema

  alias Data.Accounts.User
  alias Data.Organisations.Organisation
  alias Data.Vocabulary

  @screens Vocabulary.saved_view_screens() |> Enum.map(&String.to_atom/1)
  @columns Vocabulary.tracker_columns() |> Enum.map(&String.to_atom/1)

  @type t :: %__MODULE__{}

  schema "saved_views" do
    field(:screen, Ecto.Enum, values: @screens)
    field(:name, :string)
    field(:query, :string, default: "")
    field(:columns, {:array, Ecto.Enum}, values: @columns, default: [])
    field(:position, :integer, default: 0)

    belongs_to(:organisation, Organisation)
    belongs_to(:user, User)

    timestamps()
  end

  def changeset(view, attrs) do
    view
    |> cast(attrs, [:organisation_id, :user_id, :screen, :name, :query, :columns, :position])
    |> update_change(:name, &String.trim/1)
    |> validate_required([:organisation_id, :user_id, :screen, :name])
    |> validate_length(:name, max: 60)
    |> validate_length(:query, max: 4000)
    |> validate_number(:position, greater_than_or_equal_to: 0, less_than: 32_768)
    |> check_constraint(:screen, name: :screen_known)
    |> check_constraint(:columns, name: :columns_known)
    |> check_constraint(:name, name: :name_present, message: "can't be blank")
    |> unique_constraint(:name,
      name: :saved_views_user_screen_name_index,
      message: "is already one of your views here"
    )
  end
end
