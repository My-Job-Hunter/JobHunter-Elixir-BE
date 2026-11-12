defmodule Data.Conversations.Conversation do
  @moduledoc """
  A conversation (AQ-06 §5.2): in one team, about one customer once known,
  on one platform. `external_thread_id` is the provider's thread, a hint
  that joins it. Linked to no lead and not ignored, it is the team's
  triage item (QP6-9).
  """

  use Data.Schema

  alias Data.Accounts.User
  alias Data.Conversations.{ConversationLead, Message, Participant}
  alias Data.Customers.{Channel, Customer}
  alias Data.Organisations.Organisation
  alias Data.Teams.Team
  alias Data.Vocabulary

  @platforms Vocabulary.platforms() |> Enum.map(&String.to_atom/1)

  @type t :: %__MODULE__{}

  schema "conversations" do
    field(:platform, Ecto.Enum, values: @platforms)
    field(:external_thread_id, :string)
    field(:subject, :string)
    field(:last_message_at, :utc_datetime_usec)
    field(:ignored_at, :utc_datetime_usec)

    belongs_to(:organisation, Organisation)
    belongs_to(:team, Team)
    belongs_to(:customer, Customer)
    belongs_to(:channel, Channel)
    belongs_to(:ignored_by_user, User)
    has_many(:links, ConversationLead)
    has_many(:participants, Participant)
    has_many(:messages, Message)

    timestamps()
  end

  def changeset(conversation, attrs) do
    conversation
    |> cast(attrs, [
      :organisation_id,
      :team_id,
      :customer_id,
      :channel_id,
      :platform,
      :external_thread_id,
      :subject,
      :last_message_at,
      :ignored_at,
      :ignored_by_user_id
    ])
    |> update_change(:subject, &(&1 && String.slice(String.trim(&1), 0, 500)))
    |> validate_required([:organisation_id, :team_id, :platform])
    |> check_constraint(:platform, name: :platform_known)
    |> unique_constraint([:team_id, :platform, :external_thread_id],
      name: :conversations_thread_index,
      error_key: :external_thread_id
    )
    |> foreign_key_constraint(:customer_id)
    |> foreign_key_constraint(:channel_id)
  end
end
