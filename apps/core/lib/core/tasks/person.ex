defmodule Core.Tasks.Person do
  @moduledoc """
  A person as the board shows one (AQ-02 §7.6): `{user_id, name,
  photo_url}`, `name` the display name; the task's customer
  adds `is_customer: true` and reads as the customer is named ("Tanweer"),
  not as the account behind them is. The portal's people are first names, or "The team"
  when the task's team hides staff names (PLAN §3.4).
  """

  alias Core.Media
  alias Core.Tasks.Words
  alias Data.Accounts.Person, as: PersonRow

  @team %{user_id: nil, name: "The team", photo_url: nil}

  @doc "A user with their person loaded (and its photo), as the console shows them; `nil` for nobody."
  @spec view(map() | nil, keyword()) :: map() | nil
  def view(user, opts \\ [])
  def view(nil, _opts), do: nil

  def view(%{id: id, person: person}, opts) do
    base = %{user_id: id, name: person.display_name, photo_url: photo_url(person)}

    case Keyword.get(opts, :customer) do
      %{user_id: ^id, display_name: name} ->
        base |> Map.put(:name, name) |> Map.put(:is_customer, true)

      _staff ->
        base
    end
  end

  @doc """
  The same person as the customer reads them: themselves as they are, staff
  by first name when names are shown, else "The team".
  """
  @spec for_customer(map() | nil, map() | nil, boolean()) :: map() | nil
  def for_customer(nil, _customer, _names?), do: nil

  def for_customer(%{id: id} = user, %{user_id: id} = customer, _names?),
    do: view(user, customer: customer)

  def for_customer(user, _customer, true),
    do: %{user_id: user.id, name: first_name(user), photo_url: photo_url(user.person)}

  def for_customer(_user, _customer, false), do: @team

  @doc "The user's first name."
  def first_name(nil), do: nil
  def first_name(%{person: person}), do: Words.first_name(person)

  @doc "The link to the person's photo, or `nil`."
  def photo_url(%PersonRow{} = person) do
    case PersonRow.photo_media_id(person) do
      nil -> nil
      media_id -> Media.link(media_id)
    end
  end

  def photo_url(_person), do: nil
end
