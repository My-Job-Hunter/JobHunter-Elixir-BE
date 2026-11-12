defmodule Data.Approvals.Policy do
  @moduledoc """
  A customer's rule for one kind (AQ-07 §5.3, §8): only an override of
  Q12's defaults, which are code (`Core.Approvals.Policies`).
  """

  use Data.Schema

  alias Data.Accounts.User
  alias Data.Customers.Customer
  alias Data.Organisations.Organisation
  alias Data.Vocabulary

  @kinds Vocabulary.approval_kinds() |> Enum.map(&String.to_atom/1)
  @needs Vocabulary.approval_needs() |> Enum.map(&String.to_atom/1)
  @rules Vocabulary.approval_rules() |> Enum.map(&String.to_atom/1)

  @type t :: %__MODULE__{}

  schema "customer_approval_policies" do
    field(:approval_kind, Ecto.Enum, values: @kinds)
    field(:needs, Ecto.Enum, values: @needs)
    field(:rule, Ecto.Enum, values: @rules)
    field(:auto_approve_hours, :integer)

    belongs_to(:organisation, Organisation)
    belongs_to(:customer, Customer)
    belongs_to(:updated_by_user, User)

    timestamps()
  end

  def changeset(policy, attrs) do
    policy
    |> cast(attrs, [
      :organisation_id,
      :customer_id,
      :approval_kind,
      :needs,
      :rule,
      :auto_approve_hours,
      :updated_by_user_id
    ])
    |> validate_required([:organisation_id, :customer_id, :approval_kind, :needs, :rule])
    |> validate_number(:auto_approve_hours,
      greater_than_or_equal_to: 1,
      less_than_or_equal_to: 168
    )
    |> check_constraint(:approval_kind, name: :approval_kind_known)
    |> check_constraint(:needs, name: :needs_known)
    |> check_constraint(:rule, name: :rule_known)
    |> check_constraint(:auto_approve_hours, name: :auto_approve_hours_range)
    |> unique_constraint(:approval_kind,
      name: :customer_approval_policies_customer_id_approval_kind_index
    )
  end
end
