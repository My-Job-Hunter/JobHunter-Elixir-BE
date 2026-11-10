defmodule Data.Customers.CustomerNote do
  @moduledoc """
  A staff-only note about a customer (JH-01 §4.3): never in the portal, and
  the portal has no route that could reach one. Deleted notes keep their
  row (`deleted_at`) so the audit log's subject still resolves.
  """

  use Data.Schema

  alias Data.Accounts.User
  alias Data.Customers.Customer

  @type t :: %__MODULE__{}

  schema "customer_notes" do
    field(:body_md, :string)
    field(:edited_at, :utc_datetime_usec)
    field(:deleted_at, :utc_datetime_usec)

    belongs_to(:customer, Customer)
    belongs_to(:author_user, User)

    timestamps()
  end

  def changeset(note, attrs) do
    note
    |> cast(attrs, [:customer_id, :author_user_id, :body_md])
    |> update_change(:body_md, &(&1 && String.trim(&1)))
    |> validate_required([:customer_id, :body_md])
    |> validate_length(:body_md, min: 1, max: 20_000)
    |> check_constraint(:body_md, name: :body_present)
    |> foreign_key_constraint(:customer_id)
    |> foreign_key_constraint(:author_user_id)
  end
end
