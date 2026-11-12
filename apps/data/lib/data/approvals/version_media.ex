defmodule Data.Approvals.VersionMedia do
  @moduledoc "A version's file (AQ-07 §5.1): P1's media, in order. Each version holds its own set."

  use Data.Schema

  alias Data.Approvals.Version
  alias Data.Files.Media

  @primary_key false

  @type t :: %__MODULE__{}

  schema "approval_version_media" do
    belongs_to(:approval_version, Version, primary_key: true)
    belongs_to(:media, Media, primary_key: true)
    field(:position, :integer, default: 0)
  end

  def changeset(link, attrs) do
    link
    |> cast(attrs, [:approval_version_id, :media_id, :position])
    |> validate_required([:approval_version_id, :media_id])
    |> unique_constraint(:media_id, name: :approval_version_media_pkey)
  end
end
