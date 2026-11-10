defmodule Core.Accounts.Recovery do
  @moduledoc """
  Proving a mailbox (JH-01 §6.1): forgot and reset a password, change an
  address with confirmation. Each writes a `user_tokens` row holding a
  digest and mails the token through the `notifire` seam (`Core.Mail`).

  ## Never say whether an address is registered

  `request_password_reset/2` answers `:ok` whatever happened: no account, a
  suspended one, a real one — the same answer. The route already answers
  202 for everybody; this is the half the route cannot do.

  ## One hour, once, and it takes its siblings with it

  Using a reset consumes every other outstanding reset for that account, and
  **revokes every token** (§6.1): somebody who reset their password wants the
  stranger holding the old session gone.
  """

  alias Core.Access.Grants
  alias Core.Accounts.Password
  alias Core.Audit
  alias Core.Auth.Guardian
  alias Core.Mail
  alias Core.Plugs.RateLimit
  alias Data.Accounts
  alias Data.Accounts.User
  alias Data.Accounts.UserToken
  alias Data.Repo
  alias Data.Scope

  require Logger

  @reset_ttl_s 3600
  @change_ttl_s 86_400

  # Three an hour for one address (§6 head). Generous for somebody whose mail
  # is slow, and useless as a way to bury an inbox.
  @per_email_limit 3
  @per_email_ms 3_600_000

  @doc "How long a reset link is good for. Public so a screen can say it."
  def reset_ttl_seconds, do: @reset_ttl_s

  @doc "Asks for a reset, and **always answers `:ok`**."
  @spec request_password_reset(String.t() | nil, keyword()) :: :ok
  def request_password_reset(email, opts \\ [])

  def request_password_reset(email, opts) when is_binary(email) do
    now = Keyword.get(opts, :now) || Core.Clock.now()

    case Accounts.get_user_by_email(email) do
      %User{} = user -> if User.active?(user), do: maybe_issue(user, now, opts), else: :ok
      nil -> :ok
    end
  end

  def request_password_reset(_not_an_email, _opts), do: :ok

  # Keyed on the address, not the caller: the thing being spammed is somebody's inbox.
  defp maybe_issue(user, now, opts) do
    case RateLimit.check("password_reset:#{user.email}", @per_email_ms, @per_email_limit) do
      {:deny, _retry_after} ->
        Logger.info("password reset throttled for an address")
        :ok

      :allow ->
        issue_reset(user, now, opts)
    end
  end

  defp issue_reset(user, now, opts) do
    # A second request replaces the first: two live links is two keys.
    Accounts.consume_tokens(user, [:reset_password], now)

    case Accounts.create_token(user, :reset_password, DateTime.add(now, @reset_ttl_s, :second),
           requested_ip: Keyword.get(opts, :requested_ip)
         ) do
      {:ok, {token, row}} ->
        Mail.enqueue!(%{kind: :password_reset, subject_id: row.id, secret: token})

      {:error, _changeset} ->
        :ok
    end
  end

  @doc """
  Sets a new password from a link and **revokes every token**. A token
  nobody issued, one already used and one that has expired are the same
  answer, `:token_invalid`.
  """
  @spec reset_password(String.t() | nil, String.t() | nil, DateTime.t()) ::
          {:ok, User.t()} | {:error, :token_invalid | :password_too_weak}
  def reset_password(token, password, %DateTime{} = now) do
    with %UserToken{user: user} <-
           Accounts.get_live_token(token, [:reset_password], now) || {:error, :token_invalid},
         :ok <- Password.check(password) do
      Repo.transaction(fn -> write_reset(user, password, now) end)
    end
  end

  defp write_reset(user, password, now) do
    scope = Grants.scope_for(user)
    {:ok, user} = Accounts.set_password(user, password)
    _consumed = Accounts.consume_tokens(user, [:reset_password], now)

    if scope.organisation,
      do: Audit.record(%{scope | via: :system}, "password_reset", user, now: now)

    {:ok, _count} = Guardian.revoke_all_for(user)
    Accounts.with_person(user)
  end

  @doc """
  Asks to move the login to a new address (`POST /me/email`). **Nothing moves
  here**: a row is written and a link mailed to the new address; the login
  changes when somebody follows it. `:email_taken` when another account has
  the address.
  """
  @spec request_email_change(Scope.t(), String.t() | nil, DateTime.t()) ::
          :ok | {:error, :email_taken | Ecto.Changeset.t()}
  def request_email_change(%Scope{user: user}, new_email, %DateTime{} = now)
      when is_binary(new_email) do
    address = new_email |> String.trim() |> String.downcase()

    case Accounts.get_user_by_email(address) do
      %User{} -> {:error, :email_taken}
      nil -> issue_change(user, address, now)
    end
  end

  def request_email_change(%Scope{}, _not_an_address, _now), do: {:error, {:missing, :new_email}}

  defp issue_change(user, address, now) do
    Accounts.consume_tokens(user, [:change_email], now)

    with {:ok, {token, row}} <-
           Accounts.create_token(user, :change_email, DateTime.add(now, @change_ttl_s, :second),
             new_email: address
           ) do
      Mail.enqueue!(%{kind: :email_change, subject_id: row.id, secret: token})
    end
  end

  @doc """
  Proves the new address from the link (`POST /me/email/confirm`). The token
  must be the caller's own; anyone else's is `:token_invalid`.
  """
  @spec confirm_email_change(Scope.t(), String.t() | nil, DateTime.t()) ::
          {:ok, User.t()} | {:error, :token_invalid | :email_taken}
  def confirm_email_change(%Scope{user: %{id: user_id}} = scope, token, %DateTime{} = now) do
    case Accounts.get_live_token(token, [:change_email], now) do
      %UserToken{user: %User{id: ^user_id}} = row ->
        Repo.transaction(fn -> write_email_change(scope, row, now) end)

      _not_mine_or_dead ->
        {:error, :token_invalid}
    end
  end

  defp write_email_change(scope, row, now) do
    before = %{"email" => row.user.email}

    case Accounts.confirm_email(row, now) do
      {:ok, user} ->
        {:ok, _event} =
          Audit.record(scope, "email_changed", user,
            before: before,
            after: %{"email" => user.email},
            now: now
          )

        user

      # A changeset here means the stored address stopped being valid, which
      # nothing can produce today. It is still not a dead link.
      {:error, _taken_or_changeset} ->
        Repo.rollback(:email_taken)
    end
  end
end
