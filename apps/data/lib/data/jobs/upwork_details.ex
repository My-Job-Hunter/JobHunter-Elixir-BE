defmodule Data.Jobs.UpworkDetails do
  @moduledoc "What Upwork shows about a job and its client (AQ-03 §5.2)."

  use Data.Schema

  alias Data.Vocabulary

  @primary_key false
  @levels Vocabulary.upwork_experience_levels() |> Enum.map(&String.to_atom/1)
  @spent_bands Vocabulary.upwork_spent_bands() |> Enum.map(&String.to_atom/1)
  @fields ~w(experience_level connects_required is_client_payment_verified client_rating
             client_reviews client_country client_city client_timezone client_jobs_posted
             client_hire_rate_pct client_open_jobs client_spent_band client_hires
             client_active_hires client_avg_hourly_minor client_avg_hourly_currency
             client_member_since_on)a

  @type t :: %__MODULE__{}

  schema "job_upwork_details" do
    field(:job_id, :binary_id, primary_key: true)
    field(:experience_level, Ecto.Enum, values: @levels)
    field(:connects_required, :integer)
    field(:is_client_payment_verified, :boolean)
    field(:client_rating, :decimal)
    field(:client_reviews, :integer)
    field(:client_country, :string)
    field(:client_city, :string)
    field(:client_timezone, :string)
    field(:client_jobs_posted, :integer)
    field(:client_hire_rate_pct, :integer)
    field(:client_open_jobs, :integer)
    field(:client_spent_band, Ecto.Enum, values: @spent_bands)
    field(:client_hires, :integer)
    field(:client_active_hires, :integer)
    field(:client_avg_hourly_minor, :integer)
    field(:client_avg_hourly_currency, :string)
    field(:client_member_since_on, :date)

    timestamps()
  end

  @doc "The platform's columns, as the sheet lists them."
  def fields, do: @fields

  def changeset(details, attrs) do
    details
    |> cast(attrs, @fields)
    |> update_change(:client_country, &(&1 && String.upcase(&1)))
    |> update_change(:client_avg_hourly_currency, &(&1 && String.upcase(&1)))
    |> validate_number(:connects_required, greater_than_or_equal_to: 0, less_than: 1000)
    |> validate_number(:client_rating, greater_than_or_equal_to: 0, less_than_or_equal_to: 5)
    |> validate_number(:client_hire_rate_pct,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: 100
    )
    |> validate_format(:client_country, ~r/^[A-Z]{2}$/, message: "is not an ISO country code")
    |> validate_format(:client_avg_hourly_currency, ~r/^[A-Z]{3}$/,
      message: "is not an ISO currency code"
    )
    |> validate_change(:client_timezone, fn :client_timezone, zone ->
      case DateTime.now(zone) do
        {:ok, _now} -> []
        _unknown -> [client_timezone: "is not a known IANA timezone"]
      end
    end)
    |> check_constraint(:experience_level, name: :experience_level_known)
    |> check_constraint(:client_spent_band, name: :client_spent_band_known)
    |> check_constraint(:client_country, name: :client_country_iso)
    |> check_constraint(:client_rating, name: :client_rating_range)
    |> check_constraint(:client_hire_rate_pct, name: :client_hire_rate_pct_range)
    |> check_constraint(:client_avg_hourly_currency,
      name: :client_avg_hourly_whole,
      message: "is needed with the rate"
    )
  end
end
