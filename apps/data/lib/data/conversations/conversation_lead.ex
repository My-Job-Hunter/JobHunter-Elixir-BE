defmodule Data.Conversations.ConversationLead do
  @moduledoc "A conversation's link to a lead of its team (AQ-06 §5.2), with how it was made and how sure."

  use Data.Schema

  alias Data.Accounts.User
  alias Data.Conversations.Conversation
  alias Data.Leads.Lead
  alias Data.Vocabulary

  @methods Vocabulary.match_methods() |> Enum.map(&String.to_atom/1)
  @confidences Vocabulary.match_confidences() |> Enum.map(&String.to_atom/1)

  @primary_key false

  @type t :: %__MODULE__{}

  schema "conversation_leads" do
    belongs_to(:conversation, Conversation, primary_key: true)
    belongs_to(:lead, Lead, primary_key: true)
    field(:match_method, Ecto.Enum, values: @methods)
    field(:confidence, Ecto.Enum, values: @confidences)
    field(:inserted_at, :utc_datetime_usec, read_after_writes: true)

    belongs_to(:linked_by_user, User)
  end

  def changeset(link, attrs) do
    link
    |> cast(attrs, [:conversation_id, :lead_id, :match_method, :confidence, :linked_by_user_id])
    |> validate_required([:conversation_id, :lead_id, :match_method, :confidence])
    |> check_constraint(:match_method, name: :match_method_known)
    |> check_constraint(:confidence, name: :confidence_known)
  end
end
