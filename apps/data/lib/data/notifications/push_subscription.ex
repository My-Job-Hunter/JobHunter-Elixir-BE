defmodule Data.Notifications.PushSubscription do
  @moduledoc """
  A browser that takes Web Push for a person (AQ-08 §5, QP8-14; mCart's):
  the endpoint and keys, the app it was made on, when it was last used and
  last failed.
  """

  use Data.Schema

  alias Data.Accounts.User

  @apps Data.Vocabulary.push_apps() |> Enum.map(&String.to_atom/1)

  @type t :: %__MODULE__{}

  schema "push_subscriptions" do
    field(:app, Ecto.Enum, values: @apps)
    field(:endpoint, :string)
    field(:p256dh, :string)
    field(:auth, :string)
    field(:user_agent, :string)
    field(:last_used_at, :utc_datetime_usec)
    field(:failed_at, :utc_datetime_usec)

    belongs_to(:user, User)

    timestamps()
  end

  @doc "The apps a browser may turn push on in."
  def apps, do: @apps
end
