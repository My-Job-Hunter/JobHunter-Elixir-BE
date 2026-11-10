defmodule Data.Accounts.UserToken do
  @moduledoc """
  One outstanding one-time link (JH-01 §4.1): **reset** a password,
  **confirm** the address the account has, or **change** to a new one.

  **The token is never stored.** The row holds its SHA-256 digest; the only
  copy of the token is the one in the mail. `issue/1` mints it and returns
  it beside the attributes, the one moment the plaintext exists.
  """

  use Data.Schema

  alias Data.Accounts.User

  @type t :: %__MODULE__{}

  @purposes ~w(reset_password confirm_email change_email)a
  # 32 bytes of randomness, URL-encoded: guessing is not a strategy.
  @token_bytes 32

  schema "user_tokens" do
    field(:purpose, Ecto.Enum, values: @purposes)
    field(:token_digest, :string)
    field(:new_email, :string)
    field(:expires_at, :utc_datetime_usec)
    field(:sent_at, :utc_datetime_usec)
    field(:used_at, :utc_datetime_usec)
    field(:requested_ip, :string)

    belongs_to(:user, User)

    timestamps()
  end

  def purposes, do: @purposes

  def changeset(token, attrs) do
    token
    |> cast(attrs, [
      :user_id,
      :purpose,
      :token_digest,
      :new_email,
      :expires_at,
      :sent_at,
      :used_at,
      :requested_ip
    ])
    |> validate_required([:user_id, :purpose, :token_digest, :expires_at])
    |> update_change(:new_email, &(&1 |> String.trim() |> String.downcase()))
    |> validate_format(:new_email, ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/,
      message: "is not a valid email"
    )
    |> validate_length(:new_email, max: 160)
    |> check_constraint(:purpose, name: :purpose_known)
    |> check_constraint(:new_email, name: :new_email_only_for_a_change)
    |> unique_constraint([:purpose, :token_digest])
    |> foreign_key_constraint(:user_id)
  end

  @doc "A new token and the attributes that store it: `{token, attrs}`."
  @spec issue(map()) :: {String.t(), map()}
  def issue(%{user_id: user_id, purpose: purpose, expires_at: expires_at} = opts) do
    token = @token_bytes |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

    {token,
     %{
       user_id: user_id,
       purpose: purpose,
       token_digest: hash(token),
       new_email: Map.get(opts, :new_email),
       expires_at: expires_at,
       requested_ip: Map.get(opts, :requested_ip)
     }}
  end

  @doc """
  The digest a token is stored and looked up by. SHA-256 rather than bcrypt:
  this is 256 random bits, and a slow hash on a lookup is a denial of
  service somebody can point at you for free.
  """
  @spec hash(String.t()) :: String.t()
  def hash(token) when is_binary(token),
    do: :sha256 |> :crypto.hash(token) |> Base.encode16(case: :lower)

  @doc "Where the link goes: the new address for a change, the account's own otherwise."
  @spec address(t()) :: String.t()
  def address(%__MODULE__{purpose: :change_email, new_email: email}), do: email
  def address(%__MODULE__{user: %User{email: email}}), do: email
end
