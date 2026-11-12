defmodule Data.Extension.Config do
  @moduledoc """
  One published version of a site's selector document (AQ-05 §5.2,
  QP5-21): the file's text as published, its SHA-256 (the `ETag`), and
  when. The highest version of a site is the live one. Reference data: no
  organisation.
  """

  use Data.Schema

  alias Data.Vocabulary

  @sites Vocabulary.ext_sites() |> Enum.map(&String.to_atom/1)

  @type t :: %__MODULE__{}

  schema "extension_configs" do
    field(:site, Ecto.Enum, values: @sites)
    field(:version, :integer)
    field(:body, :string)
    field(:sha256, :string)
    field(:published_at, :utc_datetime_usec)
  end

  @doc "The digest a body is published and revalidated by, lowercase hex."
  @spec digest(String.t()) :: String.t()
  def digest(body), do: :sha256 |> :crypto.hash(body) |> Base.encode16(case: :lower)

  def changeset(config, attrs) do
    config
    |> cast(attrs, [:site, :version, :body, :published_at])
    |> validate_required([:site, :version, :body, :published_at])
    |> validate_number(:version, greater_than_or_equal_to: 1)
    |> then(fn cs ->
      case get_field(cs, :body) do
        body when is_binary(body) -> put_change(cs, :sha256, digest(body))
        nil -> cs
      end
    end)
    |> check_constraint(:site, name: :site_known)
    |> check_constraint(:version, name: :version_positive)
    |> check_constraint(:body, name: :body_present, message: "can't be blank")
    |> unique_constraint([:site, :version])
    |> unique_constraint([:site, :sha256], error_key: :body, message: "is already published")
  end
end
