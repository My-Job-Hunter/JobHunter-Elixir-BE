defmodule Data.Approvals.Version do
  @moduledoc """
  One version of an approval (AQ-07 §5.1, QP7-3): its number, its markdown
  body, the proposed value in typed columns per kind (the CV, the bid and
  Connects, the expectation, the pitch and skills) and its files
  (`approval_version_media`). Never changed once a later version exists;
  version 1 is edited only while the approval is a draft.
  """

  use Data.Schema

  alias Data.Accounts.User
  alias Data.Approvals.{Approval, VersionMedia}
  alias Data.Customers.Document
  alias Data.Vocabulary

  @kinds Vocabulary.approval_kinds() |> Enum.map(&String.to_atom/1)
  @bid_periods Vocabulary.bid_periods() |> Enum.map(&String.to_atom/1)
  @periods Vocabulary.comp_periods() |> Enum.map(&String.to_atom/1)

  @proposed ~w(proposed_document_id proposed_bid_minor proposed_bid_currency proposed_bid_period
               proposed_connects proposed_expectation_minor proposed_expectation_currency
               proposed_expectation_period proposed_title proposed_headline proposed_summary
               proposed_skill_ids)a

  @type t :: %__MODULE__{}

  schema "approval_versions" do
    field(:approval_kind, Ecto.Enum, values: @kinds)
    field(:number, :integer)
    field(:body_md, :string, default: "")
    field(:proposed_bid_minor, :integer)
    field(:proposed_bid_currency, :string)
    field(:proposed_bid_period, Ecto.Enum, values: @bid_periods)
    field(:proposed_connects, :integer)
    field(:proposed_expectation_minor, :integer)
    field(:proposed_expectation_currency, :string)
    field(:proposed_expectation_period, Ecto.Enum, values: @periods)
    field(:proposed_title, :string)
    field(:proposed_headline, :string)
    field(:proposed_summary, :string)
    field(:proposed_skill_ids, {:array, :binary_id})
    field(:inserted_at, :utc_datetime_usec)

    belongs_to(:approval, Approval)
    belongs_to(:proposed_document, Document)
    belongs_to(:created_by_user, User)

    has_many(:media_links, VersionMedia,
      foreign_key: :approval_version_id,
      preload_order: [asc: :position]
    )
  end

  @doc "The proposed columns, every kind's."
  def proposed, do: @proposed

  def changeset(version, attrs) do
    version
    |> cast(attrs, [
      :approval_id,
      :approval_kind,
      :number,
      :body_md,
      :created_by_user_id,
      :inserted_at | @proposed
    ])
    |> update_change(:body_md, &(&1 || ""))
    |> validate_required([:approval_id, :approval_kind, :number, :inserted_at])
    |> validate_length(:body_md, max: 20_000)
    |> validate_length(:proposed_title, max: 120)
    |> validate_length(:proposed_headline, max: 220)
    |> validate_length(:proposed_summary, max: 20_000)
    |> validate_number(:proposed_bid_minor, greater_than_or_equal_to: 0)
    |> validate_number(:proposed_expectation_minor, greater_than_or_equal_to: 0)
    |> validate_number(:proposed_connects, greater_than_or_equal_to: 0, less_than: 32_768)
    |> validate_format(:proposed_bid_currency, ~r/^[A-Z]{3}$/,
      message: "is not an ISO currency code"
    )
    |> validate_format(:proposed_expectation_currency, ~r/^[A-Z]{3}$/,
      message: "is not an ISO currency code"
    )
    |> check_constraint(:approval_kind, name: :approval_kind_known)
    |> check_constraint(:proposed_bid_period, name: :proposed_bid_period_known)
    |> check_constraint(:proposed_expectation_period, name: :proposed_expectation_period_known)
    |> check_constraint(:body_md, name: :body_length, message: "is too long")
    |> check_constraint(:proposed_bid_minor, name: :bid_together)
    |> check_constraint(:proposed_expectation_minor, name: :expectation_together)
    |> check_constraint(:proposed_bid_minor, name: :amounts_whole)
    |> check_constraint(:proposed_document_id, name: :cv_only_cv_for_job)
    |> check_constraint(:proposed_bid_minor, name: :bid_only_proposal)
    |> check_constraint(:proposed_expectation_minor, name: :expectation_only_rate)
    |> check_constraint(:proposed_title, name: :pitch_only_profile_change)
    |> unique_constraint(:number, name: :approval_versions_approval_id_number_index)
    |> foreign_key_constraint(:proposed_document_id)
  end
end
