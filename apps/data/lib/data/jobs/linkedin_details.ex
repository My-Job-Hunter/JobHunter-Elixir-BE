defmodule Data.Jobs.LinkedinDetails do
  @moduledoc "What LinkedIn shows about a job (AQ-03 §5.2)."

  use Data.Schema

  @primary_key false
  @fields ~w(is_easy_apply applicant_count is_applicant_count_capped is_promoted
             is_early_applicant experience_level_text employment_status_text hiring_team_text)a

  @type t :: %__MODULE__{}

  schema "job_linkedin_details" do
    field(:job_id, :binary_id, primary_key: true)
    field(:is_easy_apply, :boolean)
    field(:applicant_count, :integer)
    field(:is_applicant_count_capped, :boolean)
    field(:is_promoted, :boolean)
    field(:is_early_applicant, :boolean)
    field(:experience_level_text, :string)
    field(:employment_status_text, :string)
    field(:hiring_team_text, :string)

    timestamps()
  end

  @doc "The platform's columns, as the sheet lists them."
  def fields, do: @fields

  def changeset(details, attrs) do
    details
    |> cast(attrs, @fields)
    |> validate_number(:applicant_count, greater_than_or_equal_to: 0, less_than: 32_768)
    |> check_constraint(:applicant_count, name: :applicant_count_not_negative)
  end
end
