defmodule Data.Devices do
  @moduledoc """
  The connected extensions (AQ-05 §5.1). Storage only: who may connect,
  list and disconnect is `Core.Access`'s, the exchange and the tokens
  `Core.Extension`'s. Every read answers the device with its person, since
  every list shows who it is.
  """

  import Ecto.Query, warn: false

  alias Data.Devices.Device
  alias Data.Repo

  @preload [user: [person: :photo]]

  @doc "A device of the organisation, live or not; `nil` for a malformed or foreign id."
  @spec get(binary(), term()) :: Device.t() | nil
  def get(organisation_id, id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} ->
        Device |> Repo.get_by(id: uuid, organisation_id: organisation_id) |> load()

      :error ->
        nil
    end
  end

  def get(_organisation_id, _id), do: nil

  @doc "The live device `id` of `user_id` — what a device token's `sid` names — or `nil`."
  @spec live(binary(), term()) :: Device.t() | nil
  def live(user_id, id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} ->
        from(d in Device, where: d.id == ^uuid and d.user_id == ^user_id and is_nil(d.revoked_at))
        |> Repo.one()
        |> load()

      :error ->
        nil
    end
  end

  def live(_user_id, _id), do: nil

  @doc "Whether the person has a connected (not revoked) device: the extension channel's target (AQ-08 §4)."
  @spec connected?(binary()) :: boolean()
  def connected?(user_id) when is_binary(user_id) do
    from(d in Device, where: d.user_id == ^user_id and is_nil(d.revoked_at)) |> Repo.exists?()
  end

  @doc "The live devices: one person's (`user_id:`) or the organisation's, newest first."
  @spec list(binary(), keyword()) :: [Device.t()]
  def list(organisation_id, opts \\ []) do
    query =
      from(d in Device,
        where: d.organisation_id == ^organisation_id and is_nil(d.revoked_at),
        order_by: [desc: d.connected_at, desc: d.id],
        preload: ^@preload
      )

    case Keyword.get(opts, :user_id) do
      nil -> Repo.all(query)
      user_id -> query |> where([d], d.user_id == ^user_id) |> Repo.all()
    end
  end

  @spec create(map()) :: {:ok, Device.t()} | {:error, Ecto.Changeset.t()}
  def create(attrs) do
    with {:ok, device} <- %Device{} |> Device.create_changeset(attrs) |> Repo.insert(),
         do: {:ok, load(device)}
  end

  @doc "Disconnected at `at` by `user_id`."
  @spec revoke(Device.t(), DateTime.t(), binary() | nil) ::
          {:ok, Device.t()} | {:error, Ecto.Changeset.t()}
  def revoke(%Device{} = device, %DateTime{} = at, user_id) do
    with {:ok, revoked} <- device |> Device.revoke_changeset(at, user_id) |> Repo.update(),
         do: {:ok, load(revoked)}
  end

  @doc """
  Moves `last_seen_at` to `at` when it is older than `every_s` seconds: a
  device's requests move it at most once a minute, not on every request.
  """
  @spec seen(Device.t(), DateTime.t(), non_neg_integer()) :: :ok
  def seen(%Device{id: id}, %DateTime{} = at, every_s \\ 60) do
    since = DateTime.add(at, -every_s, :second)

    {_n, _rows} =
      from(d in Device,
        where: d.id == ^id and (is_nil(d.last_seen_at) or d.last_seen_at < ^since)
      )
      |> Repo.update_all(set: [last_seen_at: at])

    :ok
  end

  defp load(nil), do: nil
  defp load(%Device{} = device), do: Repo.preload(device, @preload, force: true)
end
