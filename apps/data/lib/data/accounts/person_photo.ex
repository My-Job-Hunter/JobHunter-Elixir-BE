defmodule Data.Accounts.PersonPhoto do
  @moduledoc """
  The link between a person and their photo in `media` (AQ-01 §4.1): one
  link table per owner, so `media` knows nothing about what it illustrates
  and `persons` carries no column that cannot hold its foreign key.
  """

  use Data.Schema

  alias Data.Accounts.Person
  alias Data.Files.Media

  @type t :: %__MODULE__{}

  schema "person_photos" do
    belongs_to(:person, Person)
    belongs_to(:media, Media)
    field(:inserted_at, :utc_datetime_usec, read_after_writes: true)
  end

  def changeset(link, attrs) do
    link
    |> cast(attrs, [:person_id, :media_id])
    |> validate_required([:person_id, :media_id])
    |> unique_constraint(:person_id)
    |> foreign_key_constraint(:person_id)
    |> foreign_key_constraint(:media_id)
  end
end
