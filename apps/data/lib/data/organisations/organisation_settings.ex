defmodule Data.Organisations.OrganisationSettings do
  @moduledoc """
  The prototype's timings as data (JH-01 §4.2), 1:1 with the organisation.
  `defaults/1` is what a reader gets when no row exists.
  """

  use Data.Schema

  @primary_key false

  @type t :: %__MODULE__{}

  @fields ~w(follow_up_gap_days max_follow_ups no_response_days similar_window_days
             inactivity_days purge_after_days warning_days observation_retention_days)a

  schema "organisation_settings" do
    field(:organisation_id, :binary_id, primary_key: true)
    field(:follow_up_gap_days, :integer, default: 3)
    field(:max_follow_ups, :integer, default: 2)
    field(:no_response_days, :integer, default: 14)
    field(:similar_window_days, :integer, default: 14)
    field(:inactivity_days, :integer, default: 90)
    field(:purge_after_days, :integer, default: 90)
    field(:warning_days, :integer, default: 7)
    field(:observation_retention_days, :integer, default: 180)

    timestamps()
  end

  @doc "The settable fields, for views and the context."
  def fields, do: @fields

  @doc "The code defaults, as a row that was never written."
  @spec defaults(binary()) :: t()
  def defaults(organisation_id), do: %__MODULE__{organisation_id: organisation_id}

  def changeset(settings, attrs) do
    changeset =
      settings
      |> cast(attrs, [:organisation_id | @fields])
      |> validate_required([:organisation_id | @fields])
      |> foreign_key_constraint(:organisation_id)

    Enum.reduce(@fields, changeset, fn field, acc ->
      acc
      |> validate_number(field, greater_than_or_equal_to: 1, less_than_or_equal_to: 365)
      |> check_constraint(field, name: :"#{field}_in_range")
    end)
  end
end
