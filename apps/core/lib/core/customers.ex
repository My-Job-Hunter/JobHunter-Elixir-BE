defmodule Core.Customers do
  @moduledoc """
  Customers (AQ-01 P1.2, §6.2 and §6.3): the people the team hunts for,
  the teams that serve them, the portal invitation and the staff-only
  notes. Profiles are `Core.Customers.Profiles`, channels
  `Core.Customers.Channels`, documents `Core.Customers.Documents`, notes
  `Core.Customers.Notes`, the skills vocabulary `Core.Customers.Skills`,
  the portal's "who serves me" `Core.Customers.Portal`.

  Every function takes a `%Data.Scope{}` first and asks `Core.Access`
  before acting; a customer the caller may not know exists is `:not_found`.
  The same verbs serve the console and the portal: a customer's scope
  reaches their own row and nobody else's, by the matrix, not by a second
  code path. Every write records an audit row inside its transaction
  (`commit/1`).
  """

  alias Core.Access
  alias Core.Audit
  alias Core.Organisation.Invitations
  alias Data.Customers
  alias Data.Customers.Customer
  alias Data.Repo
  alias Data.Scope
  alias Data.Teams

  @fields Customer.staff_fields() ++ [:status, :user_id, :archived_at]

  # ── Reads ───────────────────────────────────────────────────────────────────

  @doc """
  `GET /customers?team_id&status&q&mine`: every customer for an admin, the
  caller's teams' otherwise; a customer in no team is the system admin's
  alone (QP4a-23).
  `mine` keeps the customers with a profile the caller owns.
  """
  @spec list(Scope.t(), map()) :: {:ok, [Customer.t()]} | {:error, term()}
  def list(%Scope{organisation: organisation} = scope, params \\ %{}) do
    params = stringify(params)

    with :ok <- Access.why_not(scope, :list, {:customer, %{}}),
         {:ok, status} <- status(params["status"], required: false) do
      opts = [
        team_ids: visible_team_ids(scope, params["team_id"]),
        status: status,
        q: params["q"]
      ]

      {:ok, organisation.id |> Customers.list(opts) |> mine(scope, params["mine"])}
    end
  end

  # An admin sees every team (nil: no narrowing); staff see their own, and a
  # `team_id` filter narrows within that.
  defp visible_team_ids(scope, nil),
    do: if(Scope.admin?(scope), do: nil, else: Scope.team_ids(scope))

  defp visible_team_ids(scope, team_id) do
    if Scope.admin?(scope) or team_id in Scope.team_ids(scope), do: [team_id], else: []
  end

  defp mine(customers, scope, mine) when mine in [true, "true", "1"] do
    me = Scope.user_id(scope)

    Enum.filter(customers, fn c ->
      Enum.any?(c.profiles, fn p -> Enum.any?(p.profile_members, &(&1.user_id == me)) end)
    end)
  end

  defp mine(customers, _scope, _not_mine), do: customers

  @doc "`GET /customers/:id`, and the portal's `GET /customer` with the scope's own id."
  @spec get(Scope.t(), binary()) :: {:ok, Customer.t()} | {:error, term()}
  def get(%Scope{} = scope, id), do: fetch(scope, :read, id)

  @doc "The customer behind `id`, if the caller may take `action` on them."
  @spec fetch(Scope.t(), atom(), binary()) :: {:ok, Customer.t()} | {:error, term()}
  def fetch(%Scope{organisation: organisation} = scope, action, id) do
    with %Customer{} = customer <- Customers.get(organisation.id, id) || {:error, :not_found},
         :ok <- Access.why_not(scope, action, {:customer, customer}) do
      {:ok, customer}
    end
  end

  # ── Writes ──────────────────────────────────────────────────────────────────

  @doc """
  `POST /customers {display_name, email, phone_e164?, timezone?, location_text?,
  country_code?, started_on?, team_ids}`. The timezone defaults to the
  organisation's (QP1-2). `team_ids` is **required** (AQ-04A §8.5), each a
  team the caller leads (the system admin: any): "Only a lead of that team
  can add a customer to it."
  """
  @spec create(Scope.t(), map(), DateTime.t()) :: {:ok, Customer.t()} | {:error, term()}
  def create(%Scope{organisation: organisation} = scope, params, %DateTime{} = now) do
    params = stringify(params)

    with :ok <- Access.why_not(scope, :create, {:customer, %{}}),
         {:ok, team_ids} <- team_ids(params["team_ids"]),
         {:ok, teams} <- assignable_teams(scope, team_ids) do
      attrs =
        params
        |> Map.take(Enum.map(Customer.staff_fields(), &to_string/1))
        |> Map.put_new("timezone", organisation.timezone)
        |> Map.put("organisation_id", organisation.id)

      commit(fn -> insert(scope, attrs, teams, now) end)
    end
  end

  defp insert(scope, attrs, teams, now) do
    with {:ok, customer} <- Customers.create(attrs),
         :ok <- assign_each(scope, customer, teams, now) do
      {:ok, _event} =
        Audit.record(scope, "created", customer, after: snapshot(customer), now: now)

      {:ok, Customers.reload(customer)}
    end
  end

  defp assign_each(scope, customer, teams, now) do
    Enum.reduce_while(teams, :ok, fn team, :ok ->
      case link_team(scope, customer, team, now) do
        {:ok, _link} -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp team_ids(ids) when is_list(ids) and ids != [], do: {:ok, ids}
  defp team_ids(_none), do: {:error, {:invalid, %{"team_ids" => ["is required"]}}}

  # The teams a caller may put a customer in: any for the system admin, the
  # ones they lead otherwise (AQ-04A §8.5). A team they are not in is not
  # found; one they are staff of is refused with words.
  defp assignable_teams(%Scope{organisation: organisation} = scope, team_ids) do
    Enum.reduce_while(team_ids, {:ok, []}, fn id, {:ok, acc} ->
      with %{archived_at: nil} = team <- Teams.get(organisation.id, id) || {:error, :not_found},
           :ok <- leads_team(scope, team) do
        {:cont, {:ok, acc ++ [team]}}
      else
        %{} -> {:halt, {:error, :not_found}}
        error -> {:halt, error}
      end
    end)
  end

  defp leads_team(scope, team) do
    cond do
      Scope.admin?(scope) ->
        :ok

      Scope.team_role(scope, team.id) == :lead ->
        :ok

      Scope.team_role(scope, team.id) == :member ->
        {:error, {:forbidden, Access.customer_team_words()}}

      true ->
        {:error, :not_found}
    end
  end

  @doc "`PATCH /customers/:id` (staff: every field) and the portal's `PATCH /customer` (phone, timezone, location)."
  @spec update(Scope.t(), binary(), map()) :: {:ok, Customer.t()} | {:error, term()}
  def update(%Scope{} = scope, id, params) do
    with {:ok, customer} <- fetch(scope, :update, id) do
      allowed =
        if Scope.customer?(scope), do: Customer.portal_fields(), else: Customer.staff_fields()

      attrs = params |> stringify() |> Map.take(Enum.map(allowed, &to_string/1))
      commit(fn -> write(scope, customer, attrs) end)
    end
  end

  defp write(scope, customer, attrs) do
    with {:ok, updated} <- Customers.update(customer, attrs) do
      {:ok, _event} =
        Audit.record(scope, "updated", updated,
          before: snapshot(customer),
          after: snapshot(updated)
        )

      {:ok, Customers.reload(updated)}
    end
  end

  @doc "`POST /customers/:id/status {status}`: invited · active · paused · ended; audited."
  @spec change_status(Scope.t(), binary(), String.t() | atom(), DateTime.t()) ::
          {:ok, Customer.t()} | {:error, term()}
  def change_status(%Scope{} = scope, id, status, %DateTime{} = now) do
    with {:ok, customer} <- fetch(scope, :change_status, id),
         {:ok, status} <- status(status, required: true) do
      commit(fn ->
        {:ok, changed} = Customers.change_status(customer, status, today(customer, now))

        {:ok, _event} =
          Audit.record(scope, "status_changed", changed,
            before: snapshot(customer),
            after: snapshot(changed),
            now: now
          )

        {:ok, Customers.reload(changed)}
      end)
    end
  end

  @doc "`POST /customers/:id/teams {team_id}`."
  @spec assign_team(Scope.t(), binary(), binary(), DateTime.t()) ::
          {:ok, Customer.t()} | {:error, term()}
  def assign_team(%Scope{} = scope, id, team_id, %DateTime{} = now) do
    with {:ok, customer} <- fetch(scope, :assign_team, id),
         {:ok, [team]} <- assignable_teams(scope, [team_id || ""]) do
      commit(fn -> link_and_reload(scope, customer, team, now) end)
    end
  end

  defp link_and_reload(scope, customer, team, now) do
    with {:ok, _link} <- link_team(scope, customer, team, now),
         do: {:ok, Customers.reload(customer)}
  end

  defp link_team(scope, customer, team, now) do
    with {:ok, link} <- Customers.assign_team(customer, team.id, today(customer, now)) do
      {:ok, _event} =
        Audit.record(scope, "team_assigned", customer,
          after: %{"team_id" => team.id, "team_name" => team.name},
          now: now
        )

      {:ok, link}
    end
  end

  @doc "`DELETE /customers/:id/teams/:team_id`."
  @spec remove_team(Scope.t(), binary(), binary(), DateTime.t()) ::
          {:ok, Customer.t()} | {:error, term()}
  def remove_team(%Scope{} = scope, id, team_id, %DateTime{} = now) do
    with {:ok, customer} <- fetch(scope, :assign_team, id),
         {:ok, [team]} <- assignable_teams(scope, [team_id || ""]),
         %{} = link <- Customers.get_team_link(customer, team.id) || {:error, :not_found} do
      commit(fn ->
        {:ok, _gone} = Customers.remove_team(link)

        {:ok, _event} =
          Audit.record(scope, "team_removed", customer,
            before: %{"team_id" => team.id, "team_name" => team.name},
            now: now
          )

        {:ok, Customers.reload(customer)}
      end)
    end
  end

  @doc """
  `POST /customers/:id/invite`: a customer invitation for the customer's
  address, through `Core.Organisation.Invitations.issue/3` (the mail, the
  audit row, the one-open rule). A customer who already signs in is a
  conflict.
  """
  @spec invite(Scope.t(), binary(), DateTime.t()) ::
          {:ok, struct(), :issued | :reissued | :open} | {:error, term()}
  def invite(%Scope{} = scope, id, %DateTime{} = now) do
    with {:ok, customer} <- fetch(scope, :invite, id),
         :ok <- no_login_yet(customer) do
      Invitations.issue(
        scope,
        %{
          "kind" => "customer",
          "email" => customer.email,
          "invited_name" => customer.display_name,
          "customer_id" => customer.id
        },
        now
      )
    end
  end

  defp no_login_yet(%Customer{user_id: nil}), do: :ok
  defp no_login_yet(%Customer{}), do: {:error, :conflict}

  @doc """
  The accepted invitation (called by `Core.Organisation.Invitations.accept/3`
  inside its transaction): the login attached, `invited` becoming `active`,
  both audited. Idempotent for the same account.
  """
  @spec attach_login(Scope.t(), Customer.t(), struct(), DateTime.t()) ::
          {:ok, Customer.t()} | {:error, term()}
  def attach_login(%Scope{}, %Customer{user_id: user_id} = customer, %{id: user_id}, _now),
    do: {:ok, customer}

  def attach_login(%Scope{} = scope, %Customer{} = customer, user, %DateTime{} = now) do
    with {:ok, joined} <- Customers.attach_login(customer, user.id, today(customer, now)) do
      {:ok, _event} =
        Audit.record(scope, "joined", joined,
          before: snapshot(customer),
          after: snapshot(joined),
          now: now
        )

      {:ok, joined}
    end
  end

  # ── Helpers shared with the sibling contexts ────────────────────────────────

  @doc """
  One verb, one transaction: runs `work` (which answers `{:ok, value}` or
  `{:error, reason}`) and rolls the whole thing — the write and its audit
  row — back on an error. Answers `{:ok, value}` or `{:error, reason}`.
  """
  @spec commit((-> {:ok, term()} | {:error, term()})) :: {:ok, term()} | {:error, term()}
  def commit(work) when is_function(work, 0) do
    Repo.transaction(fn ->
      case work.() do
        {:ok, value} -> value
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @doc false
  def stringify(params), do: Map.new(params, fn {k, v} -> {to_string(k), v} end)

  @doc false
  def today(%{timezone: zone}, %DateTime{} = now) do
    case DateTime.shift_zone(now, zone) do
      {:ok, local} -> DateTime.to_date(local)
      _unknown -> DateTime.to_date(now)
    end
  end

  defp status(nil, required: false), do: {:ok, nil}

  defp status(status, _opts) when is_binary(status) do
    if status in Data.Vocabulary.customer_statuses(),
      do: {:ok, String.to_existing_atom(status)},
      else: {:error, {:missing, :status}}
  end

  defp status(status, _opts) when is_atom(status) and not is_nil(status),
    do: status |> to_string() |> status([])

  defp status(_status, _opts), do: {:error, {:missing, :status}}

  defp snapshot(customer), do: Audit.snapshot(customer, @fields)
end
