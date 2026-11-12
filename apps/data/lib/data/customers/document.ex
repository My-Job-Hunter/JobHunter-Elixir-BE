defmodule Data.Customers.Document do
  @moduledoc """
  A profile's document (AQ-01 §4.3): a CV version, a cover-letter
  template, a portfolio link, a certificate. **One row per version**: a new
  version is a new row with `version_no + 1` that supersedes the old one.
  A document has a file (`document_media`) or a `url`; `Core.Customers.Documents`
  holds the "or", since the file arrives as a separate row.
  """

  use Data.Schema

  alias Data.Customers.{DocumentMedia, Profile}

  @kinds Data.Vocabulary.document_kinds() |> Enum.map(&String.to_atom/1)

  @type t :: %__MODULE__{}

  schema "documents" do
    field(:kind, Ecto.Enum, values: @kinds)
    field(:label, :string)
    field(:version_no, :integer, default: 1)
    field(:url, :string)
    field(:archived_at, :utc_datetime_usec)

    belongs_to(:profile, Profile)
    belongs_to(:supersedes_document, __MODULE__)
    has_one(:document_media, DocumentMedia)

    timestamps()
  end

  @doc "The media behind the document, or `nil` for a link (also when not loaded)."
  @spec media(t()) :: struct() | nil
  def media(%__MODULE__{document_media: %DocumentMedia{media: %{} = media}}), do: media
  def media(%__MODULE__{}), do: nil

  def changeset(document, attrs) do
    document
    |> cast(attrs, [:profile_id, :kind, :label, :version_no, :supersedes_document_id, :url])
    |> update_change(:label, &(&1 && String.trim(&1)))
    |> update_change(:url, &(&1 && String.trim(&1)))
    |> validate_required([:profile_id, :kind, :label, :version_no])
    |> validate_length(:label, min: 1, max: 120)
    |> validate_number(:version_no, greater_than_or_equal_to: 1)
    |> validate_format(:url, ~r{^https?://\S+$}, message: "is not a web address")
    |> validate_length(:url, max: 2000)
    |> check_constraint(:kind, name: :kind_known)
    |> check_constraint(:label, name: :label_present)
    |> check_constraint(:version_no, name: :version_no_positive)
    |> check_constraint(:url, name: :url_shape)
    |> unique_constraint([:profile_id, :label, :version_no],
      error_key: :label,
      message: "already has this version"
    )
    |> foreign_key_constraint(:profile_id)
    |> foreign_key_constraint(:supersedes_document_id)
  end
end

defmodule Data.Customers.DocumentMedia do
  @moduledoc "A document's file (AQ-01 §4.3): the link to `media`, one per document."

  use Data.Schema

  alias Data.Customers.Document
  alias Data.Files.Media

  @type t :: %__MODULE__{}

  schema "document_media" do
    belongs_to(:document, Document)
    belongs_to(:media, Media)
    field(:inserted_at, :utc_datetime_usec, read_after_writes: true)
  end

  def changeset(link, attrs) do
    link
    |> cast(attrs, [:document_id, :media_id])
    |> validate_required([:document_id, :media_id])
    |> unique_constraint(:document_id)
    |> foreign_key_constraint(:document_id)
    |> foreign_key_constraint(:media_id)
  end
end
