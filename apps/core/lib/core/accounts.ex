defmodule Core.Accounts do
  @moduledoc """
  Identity (AQ-01 P1.0): signing in, the tokens, the account page, sessions
  and suspension. `Data.Accounts` stores; this decides.

  **Nobody signs up on their own** (§3): an account begins with an invitation,
  and `Core.Organisation.Invitations.accept/3` is the one caller of
  `register/3`. Recovery (forgot, reset, email change) is
  `Core.Accounts.Recovery`.

  Every function that acts for somebody takes a `%Data.Scope{}` first.
  Sign-in and Google sign-in take an address, because there is no scope yet.
  """

  alias Core.Access
  alias Core.Access.Grants
  alias Core.Accounts.Password
  alias Core.Audit
  alias Core.Auth.Google
  alias Core.Auth.Guardian
  alias Core.Broadcast
  alias Core.Clock
  alias Core.Media
  alias Core.Notifications.Deliveries
  alias Data.Accounts
  alias Data.Accounts.Person
  alias Data.Accounts.User
  alias Data.Repo
  alias Data.Scope
  alias Data.Teams

  @person_fields ~w(display_name given_name family_name timezone locale_code)a
  @person_params Enum.map(@person_fields, &to_string/1) ++ ["photo_media_id"]
  @settings_fields ~w(theme quiet_hours_start quiet_hours_end digest_time digest_on)a

  # ── Guardian's loader ───────────────────────────────────────────────────────

  @doc """
  The user behind a token's subject (`config :core, Core.Auth.Guardian,
  user_loader:`). A suspended or deactivated account answers `:not_found`,
  so every token it still holds stops working at the next request.
  """
  @spec load_user(String.t()) :: {:ok, User.t()} | {:error, :not_found}
  def load_user(id) do
    case Accounts.get_user(id) do
      %User{} = user -> if User.active?(user), do: {:ok, user}, else: {:error, :not_found}
      nil -> {:error, :not_found}
    end
  end

  # ── Signing in ──────────────────────────────────────────────────────────────

  @doc """
  Password sign-in. **The same answer for a wrong email and a wrong
  password** (`:invalid_credentials`); a suspended account is told so
  (`:account_suspended`), because the person knows they have one.
  """
  @spec sign_in(String.t() | nil, String.t() | nil, DateTime.t()) ::
          {:ok, User.t()} | {:error, :invalid_credentials | :account_suspended}
  def sign_in(email, password, %DateTime{} = now) when is_binary(email) and is_binary(password) do
    user = Accounts.get_user_by_email(email)

    if User.valid_password?(user, password),
      do: admit(user, now),
      else: {:error, :invalid_credentials}
  end

  def sign_in(_email, _password, _now), do: {:error, :invalid_credentials}

  @doc """
  *Continue with Google* (QP1-5): the account the identity is linked to, or
  the account whose email Google proved, **linked on this first use**. An
  address with no account is `:account_not_found`: nobody signs up uninvited.
  A bad token is `:invalid_credentials`.
  """
  @spec google_sign_in(String.t() | nil, DateTime.t()) ::
          {:ok, User.t()}
          | {:error, :invalid_credentials | :account_not_found | :account_suspended}
  def google_sign_in(id_token, %DateTime{} = now) do
    with {:ok, claims} <- Google.verify(id_token, now),
         {:ok, user} <- account_for(claims, now) do
      admit(user, now)
    else
      {:error, :invalid_google_token} -> {:error, :invalid_credentials}
      {:error, _reason} = error -> error
    end
  end

  defp account_for(%{subject: subject, email: email}, now) do
    case Accounts.get_user_by_identity(:google, subject) do
      %User{} = user ->
        {:ok, user}

      nil ->
        case Accounts.get_user_by_email(email) do
          nil -> {:error, :account_not_found}
          %User{} = user -> link(user, subject, email, now)
        end
    end
  end

  defp link(user, subject, email, now) do
    Repo.transaction(fn ->
      with {:ok, _identity} <- Accounts.link_identity(user, :google, subject, email, now),
           {:ok, user} <- Accounts.mark_email_confirmed(user, now) do
        user
      else
        {:error, _changeset} -> Repo.rollback(:account_not_found)
      end
    end)
  end

  # A found account, allowed in or not, and the sign-in recorded.
  defp admit(%User{} = user, now) do
    cond do
      user.suspended_at -> {:error, :account_suspended}
      not User.active?(user) -> {:error, :invalid_credentials}
      true -> record_sign_in(user, now)
    end
  end

  defp record_sign_in(user, now) do
    scope = Grants.scope_for(user)

    Repo.transaction(fn ->
      {:ok, user} = Accounts.mark_signed_in(user, now)
      if scope.organisation, do: Audit.record(scope, "signed_in", user, now: now)
      Accounts.with_person(user)
    end)
  end

  # ── Sessions ────────────────────────────────────────────────────────────────

  @doc "The session claims a sign-in mints: the device the person signed in from."
  @spec session_claims(map()) :: map()
  def session_claims(device) when is_map(device), do: %{"dev" => device}

  @doc "Ends this session: every token carrying its `sid`."
  @spec logout(Scope.t(), String.t() | nil) :: :ok
  def logout(%Scope{} = scope, sid) when is_binary(sid) do
    _removed = Accounts.revoke_session(Scope.user_id(scope), sid)
    :ok
  end

  def logout(%Scope{}, _no_sid), do: :ok

  @doc "Ends every session the person has, on every device, and drops their live sockets."
  @spec logout_all(Scope.t()) :: :ok
  def logout_all(%Scope{user: user}), do: revoke_everything(user)

  defp revoke_everything(user) do
    {:ok, _count} = Guardian.revoke_all_for(user)
    Broadcast.broadcast("user_socket:#{user.id}", "disconnect", %{})
    :ok
  end

  @doc "The live sessions, the current one marked."
  @spec list_sessions(Scope.t(), String.t() | nil, DateTime.t()) :: [map()]
  def list_sessions(%Scope{} = scope, current_sid, %DateTime{} = now) do
    for session <- Accounts.list_sessions(Scope.user_id(scope), now),
        do: Map.put(session, :is_current, session.sid == current_sid)
  end

  @doc "Ends one session by its id; `:not_found` for one that is not the caller's."
  @spec revoke_session(Scope.t(), String.t()) :: :ok | {:error, :not_found}
  def revoke_session(%Scope{} = scope, sid) when is_binary(sid) do
    case Accounts.revoke_session(Scope.user_id(scope), sid) do
      0 -> {:error, :not_found}
      _removed -> :ok
    end
  end

  # ── The account page ────────────────────────────────────────────────────────

  @doc """
  Who I am (`GET /me`): the user with their person, the roles with team
  names, settings, organisation, and `teams` for the switcher (AQ-03B §5.1):
  the person's unarchived teams by name, `{id, name, role}`; an admin gets
  every unarchived team, `role: :admin` where they hold no membership.
  """
  @spec me(Scope.t()) :: map()
  def me(%Scope{} = scope) do
    user = Accounts.with_person(scope.user)
    teams = scope |> Scope.team_ids() |> Teams.by_id()

    %{
      user: user,
      roles: %{
        admin: Scope.admin?(scope),
        teams:
          for {team_id, role} <- scope.roles.teams, team = teams[team_id] do
            %{team_id: team_id, name: team.name, role: role}
          end,
        customer_id: scope.roles.customer_id
      },
      settings: Accounts.get_settings(user.id),
      organisation: scope.organisation,
      teams: switcher(scope)
    }
  end

  defp switcher(%Scope{organisation: nil}), do: []

  defp switcher(%Scope{organisation: organisation} = scope) do
    opts = if Scope.admin?(scope), do: [], else: [ids: Scope.team_ids(scope)]

    if opts == [ids: []],
      do: [],
      else:
        for(
          team <- Teams.list(organisation.id, opts),
          do: %{id: team.id, name: team.name, role: Scope.team_role(scope, team.id) || :admin}
        )
  end

  @doc """
  Name, names, photo, timezone, locale (`PATCH /me`). The photo must be a
  photo the caller uploaded and confirmed; `nil` takes it off.
  """
  @spec update_me(Scope.t(), map()) :: {:ok, map()} | {:error, term()}
  def update_me(%Scope{user: user} = scope, params) do
    params =
      params
      |> Map.new(fn {k, v} -> {to_string(k), v} end)
      |> Map.take(@person_params)

    before = person_snapshot(Accounts.with_person(user).person)

    Repo.transaction(fn ->
      with {:ok, user} <- Accounts.update_person(user, Map.delete(params, "photo_media_id")),
           {:ok, user} <- put_photo(scope, user, params) do
        {:ok, _event} =
          Audit.record(scope, "updated", user.person,
            before: before,
            after: person_snapshot(user.person)
          )

        me(%{scope | user: user})
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp put_photo(_scope, user, %{"photo_media_id" => nil}), do: Accounts.put_photo(user, nil)

  defp put_photo(scope, user, %{"photo_media_id" => ""}),
    do: put_photo(scope, user, %{"photo_media_id" => nil})

  defp put_photo(scope, user, %{"photo_media_id" => id}) when is_binary(id) do
    case Media.own_uploaded(scope, id, :photo) do
      {:ok, media} -> Accounts.put_photo(user, media.id)
      {:error, :not_found} -> {:error, {:missing, :photo_media_id}}
    end
  end

  defp put_photo(_scope, user, _no_photo), do: {:ok, user}

  # The photo is a link row, so it joins the snapshot by hand.
  defp person_snapshot(person) do
    person
    |> Audit.snapshot(@person_fields)
    |> Map.put("photo_media_id", Person.photo_media_id(person))
  end

  @doc """
  Theme, quiet hours, digest (`PUT /me/settings`). A changed quiet-hours
  window re-plans the person's deliveries it held (AQ-08 §11.4), in the
  same transaction.
  """
  @spec put_settings(Scope.t(), map(), DateTime.t()) ::
          {:ok, struct()} | {:error, Ecto.Changeset.t()}
  def put_settings(%Scope{user: user} = scope, params, %DateTime{} = now \\ Clock.now()) do
    params =
      params
      |> Map.new(fn {k, v} -> {to_string(k), v} end)
      |> Map.take(Enum.map(@settings_fields, &to_string/1))

    previous = Accounts.get_settings(user.id)
    before = Audit.snapshot(previous, @settings_fields)

    Repo.transaction(fn ->
      case Accounts.put_settings(user.id, params) do
        {:ok, settings} ->
          {:ok, _event} =
            Audit.record(scope, "updated", settings,
              before: before,
              after: Audit.snapshot(settings, @settings_fields)
            )

          :ok = replan(previous, settings, now)
          settings

        {:error, changeset} ->
          Repo.rollback(changeset)
      end
    end)
  end

  # A changed window moves the deliveries it held (AQ-08 §11.4).
  defp replan(previous, settings, now) do
    if window(previous) != window(settings),
      do: _moved = Deliveries.replan_held(settings.user_id, now)

    :ok
  end

  defp window(settings), do: {settings.quiet_hours_start, settings.quiet_hours_end}

  @doc """
  A new password behind the current one (`POST /me/password`). A wrong
  current password is a 422 on the field, not a 401: the session is fine.
  Other sessions stay signed in.
  """
  @spec change_password(Scope.t(), String.t() | nil, String.t() | nil) ::
          :ok | {:error, Ecto.Changeset.t() | :password_too_weak}
  def change_password(%Scope{user: user} = scope, current, new) do
    with true <- User.valid_password?(user, current) || {:error, wrong_current(user)},
         :ok <- Password.check(new) do
      Repo.transaction(fn ->
        {:ok, user} = Accounts.set_password(user, new)
        {:ok, _event} = Audit.record(scope, "password_changed", user)
        :ok
      end)
      |> elem(1)
    end
  end

  defp wrong_current(user) do
    user
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.add_error(:current, "is not right")
    |> Map.put(:action, :update)
  end

  # ── Suspension ──────────────────────────────────────────────────────────────

  @doc """
  Suspends a staff account (QP1-10): by an admin, never oneself; every token
  revoked, every socket dropped; team rows kept.
  """
  @spec suspend(Scope.t(), binary(), DateTime.t()) :: {:ok, User.t()} | {:error, term()}
  def suspend(%Scope{} = scope, user_id, %DateTime{} = now) do
    with :ok <- Access.why_not(scope, :suspend_user, {:organisation, scope.organisation}),
         {:ok, target} <- staff_target(scope, user_id) do
      Repo.transaction(fn ->
        {:ok, target} = Accounts.set_suspended(target, now)
        {:ok, _event} = Audit.record(scope, "suspended", target, now: now)
        :ok = revoke_everything(target)
        target
      end)
    end
  end

  @doc "Lifts a suspension."
  @spec unsuspend(Scope.t(), binary()) :: {:ok, User.t()} | {:error, term()}
  def unsuspend(%Scope{} = scope, user_id) do
    with :ok <- Access.why_not(scope, :suspend_user, {:organisation, scope.organisation}),
         {:ok, target} <- staff_target(scope, user_id) do
      Repo.transaction(fn ->
        {:ok, target} = Accounts.set_suspended(target, nil)
        {:ok, _event} = Audit.record(scope, "unsuspended", target)
        target
      end)
    end
  end

  # Somebody of this organisation who is not the caller.
  defp staff_target(scope, user_id) do
    me = Scope.user_id(scope)

    case Accounts.get_user(user_id) do
      nil -> {:error, :not_found}
      %User{id: ^me} -> {:error, {:forbidden, "You cannot suspend your own account."}}
      %User{} = user -> if staff?(scope, user), do: {:ok, user}, else: {:error, :not_found}
    end
  end

  defp staff?(scope, user) do
    other = Grants.scope_for(user)
    organisation_id = Scope.organisation_id(scope)

    Scope.organisation_id(other) == organisation_id and
      (Scope.admin?(other) or Scope.team_ids(other) != [])
  end
end
