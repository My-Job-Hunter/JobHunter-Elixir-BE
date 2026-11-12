defmodule Data.Notifications.Preference do
  @moduledoc """
  A person's switches for one group (AQ-08 §8, QP8-6): push, email, the
  extension and the digest, each on unless turned off. No row means all on.
  """

  use Data.Schema

  alias Data.Accounts.User
  alias Data.Notifications.Group

  @primary_key false

  @type t :: %__MODULE__{}

  schema "notification_preferences" do
    belongs_to(:user, User, primary_key: true)

    belongs_to(:notification_group, Group,
      foreign_key: :notification_group_key,
      references: :key,
      type: :string,
      primary_key: true
    )

    field(:is_push_on, :boolean, default: true)
    field(:is_email_on, :boolean, default: true)
    field(:is_extension_on, :boolean, default: true)
    field(:is_digest_on, :boolean, default: true)
    field(:updated_at, :utc_datetime_usec)
  end

  @doc "The switches as `%{push, email, extension, digest}`; all on for no row."
  @spec switches(t() | nil) :: %{atom() => boolean()}
  def switches(nil), do: %{push: true, email: true, extension: true, digest: true}

  def switches(%__MODULE__{} = p),
    do: %{
      push: p.is_push_on,
      email: p.is_email_on,
      extension: p.is_extension_on,
      digest: p.is_digest_on
    }
end
