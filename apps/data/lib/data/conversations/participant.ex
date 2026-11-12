defmodule Data.Conversations.Participant do
  @moduledoc "A contact in a conversation (AQ-06 §5.2); staff and the customer are the channel's side."

  use Data.Schema

  alias Data.Contacts.Contact
  alias Data.Conversations.Conversation

  @primary_key false

  @type t :: %__MODULE__{}

  schema "conversation_participants" do
    belongs_to(:conversation, Conversation, primary_key: true)
    belongs_to(:contact, Contact, primary_key: true)
  end
end
