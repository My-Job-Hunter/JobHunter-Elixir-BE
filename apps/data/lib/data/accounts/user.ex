defmodule Data.Accounts.User do
  @moduledoc """
  An account: the login of exactly one person (AQ-01 §4.1).

  Passwords are bcrypt-hashed and the plaintext is `virtual` and `redact`ed,
  so it never reaches a log, an inspect or an error report. `hashed_password`
  is redacted too — a leaked hash is still an offline cracking target. An
  account made with Google has none until a reset sets one.

  **The password rule is `Core.Accounts.Password`'s** (QP1-6: at least ten
  characters and not on the worst-list). This changeset holds only what the
  database needs — bcrypt's 72-byte cap — so the rule lives in one place and
  is tested there.
  """

  use Data.Schema

  alias Data.Accounts.Person
  alias Data.Accounts.UserSettings

  @type t :: %__MODULE__{}

  schema "users" do
    field(:email, :string)
    field(:hashed_password, :string, redact: true)
    field(:password, :string, virtual: true, redact: true)
    field(:email_confirmed_at, :utc_datetime_usec)
    field(:welcomed_at, :utc_datetime_usec)
    field(:suspended_at, :utc_datetime_usec)
    field(:deactivated_at, :utc_datetime_usec)
    field(:delete_at, :utc_datetime_usec)
    field(:purged_at, :utc_datetime_usec)
    field(:last_signed_in_at, :utc_datetime_usec)

    belongs_to(:person, Person)
    has_one(:settings, UserSettings)

    timestamps()
  end

  @doc "A new account: the address, and a password when one is set at creation."
  def registration_changeset(user, attrs) do
    user
    |> cast(attrs, [:email, :password, :email_confirmed_at])
    |> validate_required([:email])
    |> validate_email()
    |> validate_password()
  end

  @doc "A new password, and nothing else."
  def password_changeset(user, attrs) do
    user
    |> cast(attrs, [:password])
    |> validate_required([:password])
    |> validate_password()
  end

  @doc """
  Moves the login to a proved address. **Only reachable behind a confirmed
  token** (`Data.Accounts.Tokens.confirm_email/2`).
  """
  def email_changeset(user, attrs) do
    user
    |> cast(attrs, [:email, :email_confirmed_at])
    |> validate_required([:email, :email_confirmed_at])
    |> validate_email()
  end

  @doc "Whether this account may sign in at all."
  @spec active?(t()) :: boolean()
  def active?(%__MODULE__{} = user),
    do: is_nil(user.suspended_at) and is_nil(user.deactivated_at) and is_nil(user.purged_at)

  defp validate_email(changeset) do
    changeset
    |> update_change(:email, &(&1 |> String.trim() |> String.downcase()))
    # Deliberately loose: the only proof an address works is a message arriving.
    |> validate_format(:email, ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/, message: "is not a valid email")
    |> validate_length(:email, max: 160)
    |> unsafe_validate_unique(:email, Data.Repo)
    |> unique_constraint(:email)
  end

  # 72 bytes is bcrypt's own limit — anything beyond it is silently ignored.
  defp validate_password(changeset) do
    changeset
    |> validate_length(:password, max: 72, count: :bytes)
    |> hash_password()
  end

  defp hash_password(changeset) do
    password = get_change(changeset, :password)

    if password && changeset.valid? do
      changeset
      |> put_change(:hashed_password, Bcrypt.hash_pwd_salt(password))
      |> delete_change(:password)
    else
      changeset
    end
  end

  @doc """
  Verifies a password against a user.

  Runs a dummy hash when the user is missing or has no password, so "no such
  account", "Google-only account" and "wrong password" take the same time.
  """
  @spec valid_password?(t() | nil, String.t() | nil) :: boolean()
  def valid_password?(%__MODULE__{hashed_password: hashed}, password)
      when is_binary(hashed) and is_binary(password) and byte_size(password) > 0 do
    Bcrypt.verify_pass(password, hashed)
  end

  def valid_password?(_user, _password) do
    Bcrypt.no_user_verify()
    false
  end
end
