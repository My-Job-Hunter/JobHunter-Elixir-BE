defmodule Data.Accounts.UserSettings do
  @moduledoc """
  A person's settings, 1:1 with their account (JH-01 §4.1): the theme, quiet
  hours (both null = off) and the daily digest. `defaults/1` is what a reader
  gets when no row exists yet.
  """

  use Data.Schema

  alias Data.Accounts.User

  @themes ~w(system light dark)a

  @primary_key false

  @type t :: %__MODULE__{}

  schema "user_settings" do
    field(:theme, Ecto.Enum, values: @themes, default: :system)
    field(:quiet_hours_start, :time)
    field(:quiet_hours_end, :time)
    field(:digest_time, :time, default: ~T[08:00:00])
    field(:digest_on, :boolean, default: true)

    belongs_to(:user, User, primary_key: true)

    timestamps()
  end

  @doc "The themes a screen may offer."
  def themes, do: @themes

  @doc "The code defaults, as a row that was never written."
  @spec defaults(binary()) :: t()
  def defaults(user_id), do: %__MODULE__{user_id: user_id}

  def changeset(settings, attrs) do
    settings
    |> cast(attrs, [
      :user_id,
      :theme,
      :quiet_hours_start,
      :quiet_hours_end,
      :digest_time,
      :digest_on
    ])
    |> validate_required([:user_id, :theme, :digest_time, :digest_on])
    |> validate_quiet_hours()
    |> check_constraint(:theme, name: :theme_known)
    |> foreign_key_constraint(:user_id)
    |> unique_constraint(:user_id)
  end

  # Both or neither: a window with one edge is not a window.
  defp validate_quiet_hours(changeset) do
    start = get_field(changeset, :quiet_hours_start)
    finish = get_field(changeset, :quiet_hours_end)

    if is_nil(start) == is_nil(finish),
      do: changeset,
      else: add_error(changeset, :quiet_hours_end, "needs both a start and an end")
  end
end
