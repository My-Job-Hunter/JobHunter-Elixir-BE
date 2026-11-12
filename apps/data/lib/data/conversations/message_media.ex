defmodule Data.Conversations.MessageMedia do
  @moduledoc "A message's attachment (AQ-06 §5.2): P1's media, in order, with the name the email gave it."

  use Data.Schema

  alias Data.Conversations.Message
  alias Data.Files.Media

  @primary_key false

  @type t :: %__MODULE__{}

  schema "message_media" do
    belongs_to(:message, Message, primary_key: true)
    belongs_to(:media, Media, primary_key: true)
    field(:filename, :string)
    field(:position, :integer, default: 0)
  end

  def changeset(link, attrs) do
    link
    |> cast(attrs, [:message_id, :media_id, :filename, :position])
    |> validate_required([:message_id, :media_id])
    |> unique_constraint(:media_id, name: :message_media_pkey)
  end
end
