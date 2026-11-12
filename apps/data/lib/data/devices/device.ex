defmodule Data.Devices.Device do
  @moduledoc """
  A connected extension (AQ-05 §5.1, QP5-5): the browser, the extension's
  version, when it connected and was last used, and — once disconnected —
  when and by whom. Its tokens are Guardian's, `sid` its id, `dev.app`
  `ext`; disconnecting deletes them.
  """

  use Data.Schema

  alias Data.Accounts.User
  alias Data.Organisations.Organisation

  @type t :: %__MODULE__{}

  schema "devices" do
    field(:name, :string)
    field(:agent, :string)
    field(:extension_version, :string)
    field(:connected_at, :utc_datetime_usec)
    field(:last_seen_at, :utc_datetime_usec)
    field(:revoked_at, :utc_datetime_usec)

    belongs_to(:organisation, Organisation)
    belongs_to(:user, User)
    belongs_to(:revoked_by_user, User)

    timestamps()
  end

  @doc "A new device, as `POST /ext/v1/session` makes it."
  def create_changeset(device, attrs) do
    device
    |> cast(attrs, [
      :organisation_id,
      :user_id,
      :name,
      :agent,
      :extension_version,
      :connected_at,
      :last_seen_at
    ])
    |> update_change(:name, &(&1 && String.slice(String.trim(&1), 0, 80)))
    |> update_change(:agent, &(&1 && String.slice(&1, 0, 300)))
    |> update_change(:extension_version, &(&1 && String.trim(&1)))
    |> validate_required([:organisation_id, :user_id, :name, :connected_at])
    |> validate_length(:extension_version, max: 20)
    |> check_constraint(:name, name: :name_present, message: "can't be blank")
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:organisation_id)
  end

  @doc "Disconnected, at `at`, by `user_id`."
  def revoke_changeset(device, at, user_id),
    do:
      device
      |> change(revoked_at: at, revoked_by_user_id: user_id)
      |> check_constraint(:revoked_by_user_id, name: :revoked_by_only_revoked)
end
