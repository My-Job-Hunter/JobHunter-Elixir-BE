defmodule Data.Customers.CustomerTeam do
  @moduledoc "A team serving a customer (JH-01 §4.3; PLAN Q27: several may)."

  use Data.Schema

  alias Data.Customers.Customer
  alias Data.Teams.Team

  @type t :: %__MODULE__{}

  schema "customer_teams" do
    field(:since_on, :date)

    belongs_to(:customer, Customer)
    belongs_to(:team, Team)
  end

  def changeset(link, attrs) do
    link
    |> cast(attrs, [:customer_id, :team_id, :since_on])
    |> validate_required([:customer_id, :team_id, :since_on])
    |> unique_constraint([:customer_id, :team_id], message: "already serves this customer")
    |> foreign_key_constraint(:customer_id)
    |> foreign_key_constraint(:team_id)
  end
end
