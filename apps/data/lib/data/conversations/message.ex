defmodule Data.Conversations.Message do
  @moduledoc """
  One message (AQ-06 §5.2, §11.6): its direction, who wrote it
  (`from_kind` with the key of its kind), when, its body (text, and the
  sanitised HTML of an email), its parent in the tree, the email headers
  that place it, how it arrived, and its class once a person picks one.
  A staff note is `is_internal`. Deleted, it keeps its place with no body.
  """

  use Data.Schema

  alias Data.Accounts.User
  alias Data.Contacts.Contact
  alias Data.Conversations.{Conversation, MessageMedia}
  alias Data.Files.Media
  alias Data.Organisations.Organisation
  alias Data.Vocabulary

  @directions Vocabulary.message_directions() |> Enum.map(&String.to_atom/1)
  @from_kinds Vocabulary.message_from_kinds() |> Enum.map(&String.to_atom/1)
  @captures Vocabulary.message_captures() |> Enum.map(&String.to_atom/1)
  @classes Vocabulary.message_classes() |> Enum.map(&String.to_atom/1)

  @fields ~w(organisation_id conversation_id direction is_internal from_kind from_contact_id
             from_user_id from_text to_text sent_at body_text body_html parent_message_id
             rfc_message_id in_reply_to references captured_via idempotency_key source_media_id
             created_by_user_id)a

  @type t :: %__MODULE__{}

  schema "messages" do
    field(:direction, Ecto.Enum, values: @directions)
    field(:is_internal, :boolean, default: false)
    field(:from_kind, Ecto.Enum, values: @from_kinds)
    field(:from_text, :string)
    field(:to_text, :string)
    field(:sent_at, :utc_datetime_usec)
    field(:body_text, :string)
    field(:body_html, :string)
    field(:rfc_message_id, :string)
    field(:in_reply_to, :string)
    field(:references, {:array, :string}, default: [])
    field(:captured_via, Ecto.Enum, values: @captures)
    field(:idempotency_key, :string)
    field(:classification, Ecto.Enum, values: @classes)
    field(:edited_at, :utc_datetime_usec)
    field(:deleted_at, :utc_datetime_usec)

    belongs_to(:organisation, Organisation)
    belongs_to(:conversation, Conversation)
    belongs_to(:from_contact, Contact)
    belongs_to(:from_user, User)
    belongs_to(:parent_message, __MODULE__)
    belongs_to(:source_media, Media)
    belongs_to(:classified_by_user, User)
    belongs_to(:created_by_user, User)
    has_many(:attachments, MessageMedia)
    has_many(:invites, Data.Meetings.Meeting, foreign_key: :from_message_id)

    timestamps()
  end

  def changeset(message, attrs) do
    message
    |> cast(attrs, @fields)
    |> validate_required([
      :organisation_id,
      :conversation_id,
      :direction,
      :from_kind,
      :sent_at,
      :captured_via
    ])
    |> validate_length(:body_text, max: 100_000)
    |> validate_length(:from_text, max: 500)
    |> validate_length(:to_text, max: 2000)
    |> checked()
  end

  @doc "A hand-typed message edited (QP6-8): its body, its time, its parent."
  def edit_changeset(message, attrs) do
    message
    |> cast(attrs, [:body_text, :sent_at, :parent_message_id, :edited_at])
    |> validate_length(:body_text, max: 100_000)
    |> checked()
  end

  @doc "A tombstone: no body, the place in the tree kept."
  def delete_changeset(message, %DateTime{} = at),
    do: change(message, deleted_at: at, body_text: nil, body_html: nil)

  @doc "Its class, and who picked it."
  def classify_changeset(message, class, user_id),
    do: change(message, classification: class, classified_by_user_id: user_id)

  defp checked(changeset) do
    changeset
    |> check_constraint(:direction, name: :direction_known)
    |> check_constraint(:from_kind, name: :from_kind_known)
    |> check_constraint(:captured_via, name: :captured_via_known)
    |> check_constraint(:classification, name: :classification_known)
    |> check_constraint(:from_kind, name: :one_author, message: "names one author")
    |> check_constraint(:from_kind,
      name: :from_matches_kind,
      message: "does not match who wrote it"
    )
    |> check_constraint(:is_internal,
      name: :internal_note_shape,
      message: "is a note: out, by staff, typed by hand"
    )
    |> check_constraint(:body_text, name: :body_present, message: "can't be blank")
    |> check_constraint(:parent_message_id, name: :not_its_own_parent)
    |> unique_constraint(:idempotency_key, name: :messages_organisation_id_idempotency_key_index)
    |> foreign_key_constraint(:parent_message_id)
    |> foreign_key_constraint(:from_contact_id)
  end
end
