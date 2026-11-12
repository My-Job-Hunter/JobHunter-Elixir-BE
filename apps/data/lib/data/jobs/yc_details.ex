defmodule Data.Jobs.YcDetails do
  @moduledoc "What Work at a Startup shows about a job (AQ-03 §5.2)."

  use Data.Schema

  @primary_key false
  @fields ~w(batch team_size stage_text experience_text)a

  @type t :: %__MODULE__{}

  schema "job_yc_details" do
    field(:job_id, :binary_id, primary_key: true)
    field(:batch, :string)
    field(:team_size, :integer)
    field(:stage_text, :string)
    field(:experience_text, :string)

    timestamps()
  end

  @doc "The platform's columns, as the sheet lists them."
  def fields, do: @fields

  def changeset(details, attrs) do
    details
    |> cast(attrs, @fields)
    |> update_change(:batch, &(&1 && String.upcase(String.trim(&1))))
    |> validate_format(:batch, ~r/^[WSFX][0-9]{2}$/, message: "is not a YC batch, like W24")
    |> validate_number(:team_size, greater_than_or_equal_to: 1)
    |> check_constraint(:batch, name: :batch_shape)
    |> check_constraint(:team_size, name: :team_size_positive)
  end
end
