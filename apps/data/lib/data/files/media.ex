defmodule Data.Files.Media do
  @moduledoc """
  A stored file (`media`, JH-01 §4.1): the bytes' key and what they are, and
  nothing about what they illustrate.
  """

  use Data.Schema

  @kinds ~w(photo document attachment)a

  @type t :: %__MODULE__{}

  schema "media" do
    field(:organisation_id, :binary_id)
    field(:owner_user_id, :binary_id)
    field(:media_kind, Ecto.Enum, values: @kinds)
    field(:storage_key, :string)
    field(:content_type, :string)
    field(:byte_count, :integer)
    field(:sha256, :binary)
    field(:width_px, :integer)
    field(:height_px, :integer)
    field(:page_count, :integer)
    field(:original_filename, :string)
    field(:uploaded_at, :utc_datetime_usec)
    field(:inserted_at, :utc_datetime_usec, read_after_writes: true)
  end

  @doc "The kinds a row may be."
  def kinds, do: @kinds

  def changeset(media, attrs) do
    media
    |> cast(attrs, [
      :organisation_id,
      :owner_user_id,
      :media_kind,
      :storage_key,
      :content_type,
      :byte_count,
      :width_px,
      :height_px,
      :page_count,
      :original_filename
    ])
    |> validate_required([
      :organisation_id,
      :media_kind,
      :storage_key,
      :content_type,
      :byte_count
    ])
    |> validate_number(:byte_count, greater_than: 0)
    |> validate_length(:original_filename, max: 200)
    |> check_constraint(:media_kind, name: :media_kind_known)
    |> check_constraint(:byte_count, name: :byte_count_positive)
    |> unique_constraint(:storage_key)
    |> foreign_key_constraint(:organisation_id)
    |> foreign_key_constraint(:owner_user_id)
  end
end
