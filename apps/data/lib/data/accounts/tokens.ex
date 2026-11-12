defmodule Data.Accounts.Tokens do
  @moduledoc """
  The one-time links an account is recovered and proved with (`user_tokens`).
  Storage only; the lifetimes and the answers are `Core.Accounts`'s.
  """

  import Ecto.Query, warn: false

  alias Data.Accounts.User
  alias Data.Accounts.UserToken
  alias Data.Repo

  @doc """
  Writes a token for `purpose` and hands back the plaintext beside its row:
  `{:ok, {token, row}}`. **The only moment the plaintext exists.** For a
  change, `opts[:new_email]` is the address being moved to.
  """
  @spec create_token(User.t(), atom(), DateTime.t(), keyword()) ::
          {:ok, {String.t(), UserToken.t()}} | {:error, Ecto.Changeset.t()}
  def create_token(%User{} = user, purpose, %DateTime{} = expires_at, opts \\ []) do
    {token, attrs} =
      UserToken.issue(%{
        user_id: user.id,
        purpose: purpose,
        expires_at: expires_at,
        new_email: Keyword.get(opts, :new_email),
        requested_ip: Keyword.get(opts, :requested_ip)
      })

    case %UserToken{} |> UserToken.changeset(attrs) |> Repo.insert() do
      {:ok, row} -> {:ok, {token, %{row | user: user}}}
      {:error, changeset} -> {:error, changeset}
    end
  end

  @doc """
  The row a token names, if it is still worth honouring: unused and not
  expired, of one of `purposes`. `nil` otherwise — the caller cannot tell a
  dead one from one nobody issued, and should not.
  """
  @spec get_live_token(String.t() | nil, [atom()], DateTime.t()) :: UserToken.t() | nil
  def get_live_token(token, purposes, %DateTime{} = now) when is_binary(token) do
    digest = UserToken.hash(token)

    from(t in UserToken,
      where:
        t.token_digest == ^digest and t.purpose in ^purposes and is_nil(t.used_at) and
          t.expires_at > ^now,
      preload: [user: :person]
    )
    |> Repo.one()
  end

  def get_live_token(_token, _purposes, _now), do: nil

  @doc "One by id, for the job that sends it. Unscoped, and named for it. `nil` once used."
  @spec get_token_for_system(binary()) :: UserToken.t() | nil
  def get_token_for_system(id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} ->
        from(t in UserToken, where: t.id == ^uuid and is_nil(t.used_at), preload: [user: :person])
        |> Repo.one()

      :error ->
        nil
    end
  end

  @doc "Marks one mailed, so nothing sends it twice."
  @spec mark_token_sent(UserToken.t(), DateTime.t()) ::
          {:ok, UserToken.t()} | {:error, Ecto.Changeset.t()}
  def mark_token_sent(%UserToken{} = token, %DateTime{} = at) do
    token |> Ecto.Changeset.change(sent_at: at) |> Repo.update()
  end

  @doc """
  Consumes one token, if it is still unused: `:ok`, or `:used` when another
  request spent it first (a connect code works once, AQ-05 §7).
  """
  @spec consume_token(UserToken.t(), DateTime.t()) :: :ok | :used
  def consume_token(%UserToken{id: id}, %DateTime{} = at) do
    case Repo.update_all(from(t in UserToken, where: t.id == ^id and is_nil(t.used_at)),
           set: [used_at: at, updated_at: at]
         ) do
      {1, _rows} -> :ok
      {0, _rows} -> :used
    end
  end

  @doc "Consumes every outstanding token of `purposes` for an account; answers how many."
  @spec consume_tokens(User.t(), [atom()], DateTime.t()) :: non_neg_integer()
  def consume_tokens(%User{} = user, purposes, %DateTime{} = at) do
    {consumed, _rows} =
      from(t in UserToken,
        where: t.user_id == ^user.id and t.purpose in ^purposes and is_nil(t.used_at)
      )
      |> Repo.update_all(set: [used_at: at, updated_at: at])

    consumed
  end

  @doc """
  Moves the login to the proved address, or just stamps it as proved, and
  consumes every verification, in one transaction. `{:error, :email_taken}`
  when somebody registered the address while the link sat in an inbox.
  """
  @spec confirm_email(UserToken.t(), DateTime.t()) ::
          {:ok, User.t()} | {:error, :email_taken | Ecto.Changeset.t()}
  def confirm_email(%UserToken{user: %User{} = user} = token, %DateTime{} = at) do
    Repo.transaction(fn ->
      _consumed = consume_tokens(user, [:confirm_email, :change_email], at)

      user
      |> User.email_changeset(%{"email" => UserToken.address(token), "email_confirmed_at" => at})
      |> Repo.update()
      |> case do
        {:ok, updated} -> Repo.preload(updated, :person)
        {:error, changeset} -> Repo.rollback(taken_or_changeset(changeset))
      end
    end)
  end

  defp taken_or_changeset(changeset) do
    if Keyword.has_key?(changeset.errors, :email), do: :email_taken, else: changeset
  end
end
