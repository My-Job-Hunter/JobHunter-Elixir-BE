defmodule Data.Notifications.Preferences do
  @moduledoc """
  A person's switches per group (AQ-08 §8, QP8-6), storage only: one row
  per person and group, written the first time a switch changes; no row
  means all on. Which switches a group shows and who may turn what off is
  `Core.Notifications.Settings`'s.
  """

  import Ecto.Query, warn: false

  alias Data.Notifications.Preference
  alias Data.Repo

  @doc "The person's row for one group, or `nil` (all on)."
  @spec get(binary(), String.t()) :: Preference.t() | nil
  def get(user_id, group_key),
    do: Repo.get_by(Preference, user_id: user_id, notification_group_key: group_key)

  @doc "The switches for one group as `%{push, email, extension, digest}`; all on without a row."
  @spec switches(binary(), String.t()) :: %{atom() => boolean()}
  def switches(user_id, group_key), do: user_id |> get(group_key) |> Preference.switches()

  @doc "The person's rows, by group key."
  @spec for_user(binary()) :: %{String.t() => Preference.t()}
  def for_user(user_id) do
    from(p in Preference, where: p.user_id == ^user_id)
    |> Repo.all()
    |> Map.new(&{&1.notification_group_key, &1})
  end

  @doc """
  Writes the group's switches (`%{push, email, extension, digest}`, every
  one), creating the row on first write.
  """
  @spec put(binary(), String.t(), map(), DateTime.t()) :: {:ok, Preference.t()}
  def put(user_id, group_key, %{} = switches, %DateTime{} = now) do
    row = %{
      user_id: user_id,
      notification_group_key: group_key,
      is_push_on: switches.push,
      is_email_on: switches.email,
      is_extension_on: switches.extension,
      is_digest_on: switches.digest,
      updated_at: %{now | microsecond: {elem(now.microsecond, 0), 6}}
    }

    {1, _rows} =
      Repo.insert_all(Preference, [row],
        on_conflict:
          {:replace, [:is_push_on, :is_email_on, :is_extension_on, :is_digest_on, :updated_at]},
        conflict_target: [:user_id, :notification_group_key]
      )

    {:ok, get(user_id, group_key)}
  end

  @doc "The groups in which the person turned `channel` off."
  @spec off_groups(binary(), :push | :email | :extension | :digest) :: [String.t()]
  def off_groups(user_id, channel) do
    field = field(channel)

    from(p in Preference,
      where: p.user_id == ^user_id and field(p, ^field) == false,
      select: p.notification_group_key
    )
    |> Repo.all()
  end

  defp field(:push), do: :is_push_on
  defp field(:email), do: :is_email_on
  defp field(:extension), do: :is_extension_on
  defp field(:digest), do: :is_digest_on
end
