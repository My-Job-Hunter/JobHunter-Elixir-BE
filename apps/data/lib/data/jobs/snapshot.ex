defmodule Data.Jobs.Snapshot do
  @moduledoc """
  The posting as written (AQ-03 §5.1, QP3-5): its text, with who kept it and
  how it arrived. `body_sha256` is made here, so the same text twice meets
  the unique index and stays one snapshot. `content_type: fields` (AQ-05
  QP5-12) is the extension's raw fields as JSON text.
  """

  use Data.Schema

  alias Data.Accounts.User
  alias Data.Jobs.Job
  alias Data.Vocabulary

  @origins Vocabulary.job_origins() |> Enum.map(&String.to_atom/1)

  @type t :: %__MODULE__{}

  schema "job_snapshots" do
    field(:captured_at, :utc_datetime_usec)
    field(:origin, Ecto.Enum, values: @origins, default: :manual)
    field(:content_type, Ecto.Enum, values: [:text, :html, :fields], default: :text)
    field(:body, :string)
    field(:body_sha256, :string)

    belongs_to(:job, Job)
    belongs_to(:captured_by_user, User)
  end

  @doc "The digest the unique index holds, lowercase hex."
  @spec digest(String.t()) :: String.t()
  def digest(body), do: :sha256 |> :crypto.hash(body) |> Base.encode16(case: :lower)

  def changeset(snapshot, attrs) do
    snapshot
    |> cast(attrs, [:job_id, :captured_at, :captured_by_user_id, :origin, :content_type, :body])
    |> validate_required([:job_id, :captured_at, :origin, :content_type, :body])
    |> validate_length(:body, max: 200_000)
    |> then(fn cs ->
      case get_field(cs, :body) do
        body when is_binary(body) -> put_change(cs, :body_sha256, digest(body))
        nil -> cs
      end
    end)
    |> check_constraint(:origin, name: :origin_known)
    |> check_constraint(:content_type, name: :content_type_known)
    |> check_constraint(:body, name: :body_present, message: "can't be blank")
    |> unique_constraint([:job_id, :body_sha256], error_key: :body, message: "is already kept")
    |> foreign_key_constraint(:job_id)
  end
end
