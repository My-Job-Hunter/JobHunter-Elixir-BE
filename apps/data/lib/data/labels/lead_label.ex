defmodule Data.Labels.LeadLabel do
  @moduledoc "A label on a lead (AQ-04B §5.1): the pair is the key."

  use Ecto.Schema

  @primary_key false
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{}

  schema "lead_labels" do
    belongs_to(:lead, Data.Leads.Lead, primary_key: true)
    belongs_to(:label, Data.Labels.Label, primary_key: true)
  end
end
