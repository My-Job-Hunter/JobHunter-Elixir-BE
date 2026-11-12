defmodule Data.Jobs.IndeedDetails do
  @moduledoc "What Indeed shows about a job (AQ-03 §5.2)."

  use Data.Schema

  @primary_key false
  @fields ~w(is_easily_apply is_responsive_employer is_urgently_hiring work_setting_text)a

  @type t :: %__MODULE__{}

  schema "job_indeed_details" do
    field(:job_id, :binary_id, primary_key: true)
    field(:is_easily_apply, :boolean)
    field(:is_responsive_employer, :boolean)
    field(:is_urgently_hiring, :boolean)
    field(:work_setting_text, :string)

    timestamps()
  end

  @doc "The platform's columns, as the sheet lists them."
  def fields, do: @fields

  def changeset(details, attrs),
    do: details |> cast(attrs, @fields) |> validate_length(:work_setting_text, max: 200)
end
