defmodule Core.Organisation.Invitations do
  @moduledoc """
  The front door (AQ-01 §3, §6.1, §6.2). An invitation names what the
  person becomes; the link opens `/invite/:code`; accepting makes the account
  or adds the role, and signs the person in.

  Seven days to live (QP1-1), one use, at most one open per target; resend
  extends. The mail goes out through `Core.Mail` (`notifire` delivers), and
  `accept_url/1` is the link it carries.
  """

  alias Core.Access
  alias Core.Accounts.Password
  alias Core.Audit
  alias Core.Auth.Google
  alias Core.Mail
  alias Core.Organisation.Teams
  alias Data.Accounts
  alias Data.Accounts.User
  alias Data.Invitations
  alias Data.Invitations.Invitation
  alias Data.Organisations
  alias Data.Repo
  alias Data.Scope

  @ttl_days 7
  @fields ~w(kind email invited_name team_id role customer_id expires_at accepted_at revoked_at)a

  @doc "How long an invitation lives."
  def ttl_days, do: @ttl_days

  @doc """
  The link the mail carries: the console's origin for staff, the portal's
  for a customer (`config :core, :app_urls`; `CONSOLE_URL`/`PORTAL_URL` in
  a release).
  """
  @spec accept_url(Invitation.t()) :: String.t()
  def accept_url(%Invitation{kind: kind, code: code}) do
    urls = Application.get_env(:core, :app_urls, [])
    base = if kind == :customer, do: urls[:portal], else: urls[:console]
    "#{base || "http://localhost:5800"}/invite/#{code}"
  end

  # ── Staff side ──────────────────────────────────────────────────────────────

  @doc "`GET /invitations?state=open`: all for the system admin, the caller's teams' for a team lead."
  @spec list(Scope.t(), map()) :: {:ok, [Invitation.t()]} | {:error, term()}
  def list(%Scope{organisation: organisation} = scope, params \\ %{}) do
    with :ok <- Access.why_not(scope, :list, {:invitation, %{}}) do
      state = if (params[:state] || params["state"]) == "open", do: :open, else: nil
      team_ids = if Scope.admin?(scope), do: nil, else: Scope.team_ids(scope)

      {:ok,
       Invitations.list(organisation.id, state: state, now: Core.Clock.now(), team_ids: team_ids)}
    end
  end

  @doc """
  `POST /invitations {kind, email, invited_name, team_id?, role?}`: issues a
  new one, or **resends the open one** for the same target. Answers
  `{:ok, invitation, :issued | :reissued | :open}`.
  """
  @spec issue(Scope.t(), map(), DateTime.t()) :: {:ok, Invitation.t(), atom()} | {:error, term()}
  def issue(%Scope{organisation: organisation} = scope, params, %DateTime{} = now) do
    params = Map.new(params, fn {k, v} -> {to_string(k), v} end)

    with {:ok, kind} <- kind(params["kind"]),
         :ok <- not_admin(scope, kind),
         {:ok, target, subject} <- target(scope, kind, params),
         :ok <- Access.why_not(scope, :create, {:invitation, subject}),
         :ok <- within_reach(scope, kind, params) do
      email = (params["email"] || "") |> String.trim() |> String.downcase()

      case Invitations.open_for(organisation.id, kind, email, target) do
        %Invitation{} = open -> reissue(scope, open, now)
        nil -> create(scope, kind, email, params, now)
      end
    end
  end

  defp create(%Scope{organisation: organisation} = scope, kind, email, params, now) do
    attrs = %{
      organisation_id: organisation.id,
      kind: kind,
      code: unique_code(),
      email: email,
      invited_name: params["invited_name"],
      team_id: params["team_id"],
      role: params["role"],
      customer_id: params["customer_id"],
      invited_by_user_id: Scope.user_id(scope),
      expires_at: DateTime.add(now, @ttl_days, :day)
    }

    Repo.transaction(fn ->
      case Invitations.create(attrs) do
        {:ok, invitation} ->
          {:ok, _event} =
            Audit.record(scope, "invited", invitation, after: snapshot(invitation), now: now)

          :ok = Mail.enqueue!(%{kind: :invitation, subject_id: invitation.id})
          invitation

        {:error, changeset} ->
          Repo.rollback(changeset)
      end
    end)
    |> case do
      {:ok, invitation} -> {:ok, invitation, :issued}
      {:error, reason} -> {:error, reason}
    end
  end

  # An open invitation for the same target: extended and mailed again if it
  # had lapsed, left alone (and mailed again) if it is still live.
  defp reissue(scope, invitation, now) do
    status = if Invitation.state(invitation, now) == :expired, do: :reissued, else: :open

    Repo.transaction(fn ->
      {:ok, invitation} = Invitations.extend(invitation, DateTime.add(now, @ttl_days, :day))

      {:ok, _event} =
        Audit.record(scope, "resent", invitation, after: snapshot(invitation), now: now)

      :ok = Mail.enqueue!(%{kind: :invitation, subject_id: invitation.id})
      invitation
    end)
    |> case do
      {:ok, invitation} -> {:ok, invitation, status}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "`POST /invitations/:id/resend`: a fresh week and the mail again."
  @spec resend(Scope.t(), binary(), DateTime.t()) :: {:ok, Invitation.t()} | {:error, term()}
  def resend(%Scope{} = scope, id, %DateTime{} = now) do
    with {:ok, invitation} <- fetch(scope, :revoke, id),
         :open <- open_or_expired(invitation, now),
         {:ok, invitation, _status} <- reissue(scope, invitation, now) do
      {:ok, invitation}
    else
      :accepted -> {:error, :invitation_used}
      :revoked -> {:error, :invitation_invalid}
      error -> error
    end
  end

  @doc "`POST /invitations/:id/revoke`."
  @spec revoke(Scope.t(), binary(), DateTime.t()) :: {:ok, Invitation.t()} | {:error, term()}
  def revoke(%Scope{} = scope, id, %DateTime{} = now) do
    with {:ok, invitation} <- fetch(scope, :revoke, id),
         :open <- open_or_expired(invitation, now) do
      Repo.transaction(fn ->
        {:ok, revoked} = Invitations.revoke(invitation, now)

        {:ok, _event} =
          Audit.record(scope, "revoked", revoked,
            before: snapshot(invitation),
            after: snapshot(revoked),
            now: now
          )

        revoked
      end)
    else
      :accepted -> {:error, :invitation_used}
      :revoked -> {:error, :invitation_invalid}
      error -> error
    end
  end

  defp open_or_expired(invitation, now) do
    case Invitation.state(invitation, now) do
      :expired -> :open
      state -> state
    end
  end

  defp fetch(%Scope{organisation: organisation} = scope, action, id) do
    with %Invitation{} = invitation <-
           Invitations.get(organisation.id, id) || {:error, :not_found},
         :ok <- Access.why_not(scope, action, {:invitation, invitation}) do
      {:ok, invitation}
    end
  end

  # ── The person's side ───────────────────────────────────────────────────────

  @doc """
  `GET /auth/invitations/:code`: what this invitation is, before accepting.
  `:invitation_invalid` for an unknown or revoked code, `:invitation_used`
  for an accepted one, `{:invitation_expired, expires_at}` for a lapsed one
  (the screen says when).
  """
  @spec preview(String.t(), DateTime.t()) :: {:ok, map()} | {:error, term()}
  def preview(code, %DateTime{} = now) do
    with {:ok, invitation} <- live(code, now) do
      {:ok,
       %{
         kind: invitation.kind,
         organisation_name: invitation.organisation.name,
         team_name: invitation.team && invitation.team.name,
         role: invitation.role,
         customer_name: invitation.customer && invitation.customer.display_name,
         invited_name: invitation.invited_name,
         invited_by: invited_by_name(invitation),
         email: invitation.email,
         expires_at: invitation.expires_at,
         has_account: not is_nil(Accounts.get_user_by_email(invitation.email))
       }}
    end
  end

  @doc "The display name of whoever issued it, or `nil` (the bootstrap)."
  @spec invited_by_name(Invitation.t()) :: String.t() | nil
  def invited_by_name(%Invitation{invited_by_user: %{person: %{display_name: name}}}), do: name
  def invited_by_name(%Invitation{}), do: nil

  defp live(code, now) do
    case Invitations.get_by_code(code) do
      nil ->
        {:error, :invitation_invalid}

      %Invitation{} = invitation ->
        case Invitation.state(invitation, now) do
          :open -> {:ok, invitation}
          :accepted -> {:error, :invitation_used}
          :expired -> {:error, {:invitation_expired, invitation.expires_at}}
          :revoked -> {:error, :invitation_invalid}
        end
    end
  end

  @doc """
  `POST /auth/invitations/:code/accept {name?, password?, id_token?}`, or
  signed in. A new person sets a name and a password (QP1-6) or continues
  with Google; an existing account with the same email accepts with one
  press. Answers `{:ok, %{user, landing, how: :created | :joined}}`.
  """
  @spec accept(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def accept(code, params, opts \\ []) do
    now = Keyword.get(opts, :now) || Core.Clock.now()
    params = Map.new(params, fn {k, v} -> {to_string(k), v} end)

    with {:ok, invitation} <- live(code, now),
         {:ok, how} <- who(invitation, Keyword.get(opts, :current_user), params, now) do
      join(invitation, how, params, now)
    end
  end

  # Which account accepts: the signed-in one, the one Google proves, the one
  # the email already has (which must sign in), or a new one.
  defp who(invitation, %User{} = current, _params, _now) do
    if same_address?(current.email, invitation.email),
      do: {:ok, {:existing, current}},
      else:
        {:error,
         {:forbidden, "This invitation is for #{invitation.email}. Sign in with that account."}}
  end

  defp who(invitation, nil, %{"id_token" => id_token}, now) when is_binary(id_token) do
    with {:ok, claims} <- Google.verify(id_token, now),
         true <- same_address?(claims.email, invitation.email) || {:error, :invalid_credentials} do
      case Accounts.get_user_by_email(invitation.email) do
        %User{} = user -> {:ok, {:existing_google, user, claims}}
        nil -> {:ok, {:new_google, claims}}
      end
    else
      {:error, :invalid_google_token} -> {:error, :invalid_credentials}
      error -> error
    end
  end

  defp who(invitation, nil, params, _now) do
    case Accounts.get_user_by_email(invitation.email) do
      %User{} ->
        {:error, :email_taken}

      nil ->
        with(:ok <- Password.check(params["password"]), do: {:ok, {:new, params["password"]}})
    end
  end

  defp same_address?(a, b),
    do: String.downcase(String.trim(a || "")) == String.downcase(String.trim(b || ""))

  defp join(invitation, how, params, now) do
    organisation = invitation.organisation

    Repo.transaction(fn ->
      with {:ok, user, created} <- account(invitation, how, params, now),
           scope = Scope.for_user(user) |> Map.put(:organisation, organisation),
           {:ok, _role} <- grant(scope, invitation, user, now),
           {:ok, accepted} <- Invitations.accept(invitation, user.id, now) do
        {:ok, _event} =
          Audit.record(scope, "accepted", accepted,
            before: snapshot(invitation),
            after: snapshot(accepted),
            now: now
          )

        %{user: Accounts.with_person(user), landing: landing(invitation), how: created}
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp account(_invitation, {:existing, user}, _params, _now), do: {:ok, user, :joined}

  defp account(_invitation, {:existing_google, user, claims}, _params, now) do
    case Accounts.get_user_by_identity(:google, claims.subject) do
      %User{id: id} when id == user.id ->
        {:ok, user, :joined}

      nil ->
        with(
          {:ok, _identity} <-
            Accounts.link_identity(user, :google, claims.subject, claims.email, now),
          do: {:ok, user, :joined}
        )

      %User{} ->
        {:error, :invalid_credentials}
    end
  end

  defp account(invitation, {:new, password}, params, now) do
    with {:ok, user} <- register(invitation, params["name"], %{"password" => password}, now) do
      {:ok, user, :created}
    end
  end

  defp account(invitation, {:new_google, claims}, params, now) do
    with {:ok, user} <-
           register(
             invitation,
             params["name"] || claims.name,
             %{"email_confirmed_at" => now},
             now
           ),
         {:ok, _identity} <-
           Accounts.link_identity(user, :google, claims.subject, claims.email, now) do
      {:ok, user, :created}
    end
  end

  # The person takes the organisation's timezone (QP1-2) — a customer the
  # one staff set on their record — and the invited name unless they typed one.
  defp register(invitation, name, extra, now) do
    attrs =
      Map.merge(extra, %{
        "display_name" =>
          blank(name) || invitation.invited_name || hd(String.split(invitation.email, "@")),
        "timezone" => timezone(invitation),
        "email" => invitation.email
      })

    with {:ok, user} <- Accounts.register_user(attrs) do
      scope = Scope.system(invitation.organisation)

      {:ok, _event} =
        Audit.record(scope, "created", user, after: %{"email" => user.email}, now: now)

      {:ok, user}
    end
  end

  defp grant(scope, %Invitation{kind: :admin} = invitation, user, now) do
    case Organisations.get_admin(invitation.organisation_id, user.id) do
      nil ->
        with {:ok, admin} <-
               Organisations.grant_admin(%{
                 organisation_id: invitation.organisation_id,
                 user_id: user.id,
                 granted_at: now
               }) do
          {:ok, _event} =
            Audit.record(scope, "joined", admin, after: %{"user_id" => user.id}, now: now)

          {:ok, admin}
        end

      admin ->
        {:ok, admin}
    end
  end

  defp grant(scope, %Invitation{kind: :team_member} = invitation, user, now) do
    Teams.add_member(scope, invitation.team, user, invitation.role, now)
  end

  # The customer gains their login (`customers.user_id`) and becomes active.
  defp grant(scope, %Invitation{kind: :customer, customer: %{} = customer}, user, now) do
    Core.Customers.attach_login(scope, customer, user, now)
  end

  defp grant(_scope, %Invitation{kind: :customer}, _user, _now), do: {:error, :invitation_invalid}

  defp timezone(%Invitation{kind: :customer, customer: %{timezone: zone}}) when is_binary(zone),
    do: zone

  defp timezone(%Invitation{organisation: organisation}), do: organisation.timezone

  # Staff land on the console's home; a customer on Profiles (QP1-12).
  defp landing(%Invitation{kind: :customer}), do: "/profiles"
  defp landing(_staff), do: "/"

  # ── Helpers ─────────────────────────────────────────────────────────────────

  defp kind(kind) when kind in ~w(admin team_member customer),
    do: {:ok, String.to_existing_atom(kind)}

  defp kind(kind) when kind in [:admin, :team_member, :customer], do: {:ok, kind}
  defp kind(_kind), do: {:error, {:missing, :kind}}

  # The target a kind points at, checked to exist where the caller may see
  # it, and the subject `Core.Access` decides on.
  defp target(_scope, :admin, _params), do: {:ok, nil, %{kind: :admin}}

  defp target(%Scope{organisation: organisation}, :team_member, params) do
    case Data.Teams.get(organisation.id, params["team_id"] || "") do
      %{archived_at: nil} = team -> {:ok, team.id, %{kind: :team_member, team_id: team.id}}
      _missing -> {:error, :not_found}
    end
  end

  defp target(%Scope{organisation: organisation}, :customer, params) do
    case Data.Customers.get(organisation.id, params["customer_id"] || "") do
      %{archived_at: nil} = customer -> {:ok, customer.id, %{kind: :customer, customer: customer}}
      _missing -> {:error, :not_found}
    end
  end

  # The one admin invitation is the bootstrap's (AQ-04A §8.5, QP4a-21): from
  # a route, `kind: admin` is a field error.
  defp not_admin(%Scope{via: :system, user: nil}, :admin), do: :ok

  defp not_admin(_scope, :admin),
    do: {:error, {:invalid, %{"kind" => ["is team_member or customer"]}}}

  defp not_admin(_scope, _kind), do: :ok

  # A team lead invites staff; a team lead is the system admin's to invite
  # (AQ-04A §8.5).
  defp within_reach(scope, :team_member, %{"role" => role}) do
    if to_string(role) == "lead" and not Scope.admin?(scope),
      do: {:error, {:forbidden, Access.admin_words()}},
      else: :ok
  end

  defp within_reach(_scope, _kind, _params), do: :ok

  defp unique_code do
    code = Invitation.generate_code()
    if Invitations.get_by_code(code), do: unique_code(), else: code
  end

  defp snapshot(invitation), do: Audit.snapshot(invitation, @fields)

  defp blank(nil), do: nil

  defp blank(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end
end
