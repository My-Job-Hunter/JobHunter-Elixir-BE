defmodule Data.Accounts do
  @moduledoc """
  Persons, users, identities and settings. **Storage only — no business
  rules.** Who may register, what a password must be and who may do what live
  in `core`; this app reads and writes rows.

  The one-time links are `Data.Accounts.Tokens`, the sessions
  `Data.Accounts.Sessions`; both are delegated from here so every caller asks
  one module.
  """

  import Ecto.Query, warn: false

  alias Data.Accounts.{Person, PersonPhoto, Sessions, Tokens, User, UserIdentity, UserSettings}
  alias Data.Repo
  alias Ecto.Multi

  # ── Reads ───────────────────────────────────────────────────────────────────

  @doc "An account by id, with its person; `nil` for an unknown or malformed id."
  @spec get_user(binary()) :: User.t() | nil
  def get_user(id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> User |> Repo.get(uuid) |> Repo.preload(:person)
      :error -> nil
    end
  end

  def get_user(_id), do: nil

  @doc "An account by address (citext: any case), with its person."
  @spec get_user_by_email(String.t()) :: User.t() | nil
  def get_user_by_email(email) when is_binary(email) do
    User |> Repo.get_by(email: String.trim(email)) |> Repo.preload(:person)
  end

  def get_user_by_email(_email), do: nil

  @doc "The account a provider's identity is linked to, or `nil`."
  @spec get_user_by_identity(atom(), String.t()) :: User.t() | nil
  def get_user_by_identity(provider, subject) when is_binary(subject) do
    from(u in User,
      join: i in UserIdentity,
      on: i.user_id == u.id,
      where: i.provider == ^provider and i.provider_subject == ^subject,
      preload: :person
    )
    |> Repo.one()
  end

  @doc "Accounts by id, with their persons, as `%{id => user}`."
  @spec users_by_id([binary()]) :: %{binary() => User.t()}
  def users_by_id([]), do: %{}

  def users_by_id(ids) do
    from(u in User, where: u.id in ^ids, preload: :person)
    |> Repo.all()
    |> Map.new(&{&1.id, &1})
  end

  @doc "The account with its person and the person's photo link loaded."
  @spec with_person(User.t()) :: User.t()
  def with_person(%User{} = user), do: Repo.preload(user, person: :photo)

  # ── Writes ──────────────────────────────────────────────────────────────────

  @doc """
  Makes a person and their account in one transaction. `attrs` carries the
  person's `display_name` and `timezone`, and the user's `email` and
  (optionally) `password`; the person's errors are carried onto the user's
  changeset so a form sees one set.
  """
  @spec register_user(map()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def register_user(attrs) do
    attrs = stringify(attrs)

    person =
      Person.changeset(
        %Person{},
        Map.take(attrs, ~w(display_name given_name family_name timezone locale_code))
      )

    user =
      User.registration_changeset(%User{}, Map.take(attrs, ~w(email password email_confirmed_at)))

    user = carry_errors(user, person)

    if user.valid? do
      Multi.new()
      |> Multi.insert(:person, person)
      |> Multi.insert(:user, fn %{person: p} ->
        Ecto.Changeset.put_change(user, :person_id, p.id)
      end)
      |> Repo.transaction()
      |> case do
        {:ok, %{user: user, person: person}} -> {:ok, %{user | person: person}}
        {:error, _step, changeset, _done} -> {:error, changeset}
      end
    else
      {:error, %{user | action: :insert}}
    end
  end

  defp carry_errors(target, source) do
    Enum.reduce(source.errors, target, fn {field, {message, opts}}, acc ->
      Ecto.Changeset.add_error(acc, field, message, opts)
    end)
  end

  @doc "The person's name, names, zone and language."
  @spec update_person(User.t(), map()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def update_person(%User{} = user, attrs) do
    user = with_person(user)

    with {:ok, person} <- user.person |> Person.changeset(attrs) |> Repo.update() do
      {:ok, %{user | person: person}}
    end
  end

  @doc """
  The person's photo: a media id, or nil to take it off. The link row
  (`person_photos`) is written or removed; the person is answered with it.
  """
  @spec put_photo(User.t(), binary() | nil) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def put_photo(%User{} = user, media_id) do
    user = with_person(user)
    person = user.person

    result =
      case {person.photo, media_id} do
        {nil, nil} ->
          {:ok, nil}

        {%PersonPhoto{} = link, nil} ->
          with {:ok, _gone} <- Repo.delete(link), do: {:ok, nil}

        {nil, id} ->
          %PersonPhoto{}
          |> PersonPhoto.changeset(%{person_id: person.id, media_id: id})
          |> Repo.insert()

        {%PersonPhoto{} = link, id} ->
          link |> PersonPhoto.changeset(%{media_id: id}) |> Repo.update()
      end

    with {:ok, link} <- result, do: {:ok, %{user | person: %{person | photo: link}}}
  end

  @doc "Writes a new password **without asking for the old one**: the caller has proved otherwise."
  @spec set_password(User.t(), String.t() | nil) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def set_password(%User{} = user, password) do
    user |> User.password_changeset(%{"password" => password}) |> Repo.update()
  end

  @doc "Stamps the moment of a sign-in."
  @spec mark_signed_in(User.t(), DateTime.t()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def mark_signed_in(%User{} = user, %DateTime{} = at) do
    user |> Ecto.Changeset.change(last_signed_in_at: at) |> Repo.update()
  end

  @doc "Stamps an account's address as proved. A no-op when it already is."
  @spec mark_email_confirmed(User.t(), DateTime.t()) ::
          {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def mark_email_confirmed(%User{email_confirmed_at: nil} = user, %DateTime{} = at) do
    user |> Ecto.Changeset.change(email_confirmed_at: at) |> Repo.update()
  end

  def mark_email_confirmed(%User{} = user, _at), do: {:ok, user}

  @doc "Suspends (`at`) or lifts (`nil`) an account. Revocation is the caller's."
  @spec set_suspended(User.t(), DateTime.t() | nil) ::
          {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def set_suspended(%User{} = user, at) do
    user |> Ecto.Changeset.change(suspended_at: at) |> Repo.update()
  end

  @doc "Links a provider's identity to an account."
  @spec link_identity(User.t(), atom(), String.t(), String.t() | nil, DateTime.t()) ::
          {:ok, UserIdentity.t()} | {:error, Ecto.Changeset.t()}
  def link_identity(%User{} = user, provider, subject, email, %DateTime{} = at) do
    %UserIdentity{}
    |> UserIdentity.changeset(%{
      user_id: user.id,
      provider: provider,
      provider_subject: subject,
      email: email,
      linked_at: at
    })
    |> Repo.insert()
  end

  # ── Settings ────────────────────────────────────────────────────────────────

  @doc "The row, or the code defaults when there is none."
  @spec get_settings(binary()) :: UserSettings.t()
  def get_settings(user_id) do
    Repo.get_by(UserSettings, user_id: user_id) || UserSettings.defaults(user_id)
  end

  @doc "Writes the settings, creating the row on first write."
  @spec put_settings(binary(), map()) :: {:ok, UserSettings.t()} | {:error, Ecto.Changeset.t()}
  def put_settings(user_id, attrs) do
    case Repo.get_by(UserSettings, user_id: user_id) do
      nil ->
        %UserSettings{}
        |> UserSettings.changeset(Map.put(stringify(attrs), "user_id", user_id))
        |> Repo.insert()

      row ->
        row |> UserSettings.changeset(attrs) |> Repo.update()
    end
  end

  # ── One-time links and sessions ─────────────────────────────────────────────

  defdelegate create_token(user, purpose, expires_at, opts \\ []), to: Tokens
  defdelegate get_live_token(token, purposes, now), to: Tokens
  defdelegate get_token_for_system(id), to: Tokens
  defdelegate mark_token_sent(token, at), to: Tokens
  defdelegate consume_tokens(user, purposes, at), to: Tokens
  defdelegate consume_token(token, at), to: Tokens
  defdelegate confirm_email(token, at), to: Tokens

  defdelegate list_sessions(user_id, now), to: Sessions
  defdelegate revoke_session(user_id, sid), to: Sessions

  defp stringify(attrs), do: Map.new(attrs, fn {key, value} -> {to_string(key), value} end)
end
