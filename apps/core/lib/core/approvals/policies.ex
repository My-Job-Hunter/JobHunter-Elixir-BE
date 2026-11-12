defmodule Core.Approvals.Policies do
  @moduledoc """
  A customer's approval rules (AQ-07 §8, QP7-16; PLAN Q12): **Q12's
  defaults are code**, and only a team lead's overrides are stored
  (`customer_approval_policies`), as mCart keeps its settings 1:1 with
  defaults.

  | Kind | Needs | Rule |
  |---|---|---|
  | `cv_for_job` · `proposal` · `rate` · `profile_change` | customer | any |
  | `reply` | team lead | any |
  | `cover_letter` · `asset` · `other` | ad hoc (the requester picks the slots) | any |

  Auto-approve is off for every kind. **Customer › Approvals** reads the
  eight rows (`list/2`), each the default or the override (`is_default`);
  a team lead of a team serving the customer, or the system admin, puts
  *Needs*, *Rule* and *Auto-approve after* (off · 4 · 12 · 24 · 48 h) or
  takes a kind back to its default. `both` makes two slots, customer and
  team lead.
  """

  alias Core.Access
  alias Core.Approvals.Ask
  alias Core.Audit
  alias Core.Customers
  alias Core.Leads
  alias Data.Approvals, as: Store
  alias Data.Scope
  alias Data.Vocabulary

  @kinds Vocabulary.approval_kinds() |> Enum.map(&String.to_atom/1)
  @customer ~w(cv_for_job proposal rate profile_change)a
  @hours [nil, 4, 12, 24, 48]

  @doc "Q12's default for a kind: `%{approval_kind, needs, rule, auto_approve_hours: nil, is_default: true}`."
  @spec default(atom()) :: map()
  def default(kind) when kind in @kinds do
    needs =
      cond do
        kind in @customer -> :customer
        kind == :reply -> :team_lead
        true -> :ad_hoc
      end

    %{approval_kind: kind, needs: needs, rule: :any, auto_approve_hours: nil, is_default: true}
  end

  @doc "The rule in force for a customer and a kind: the override, else the default."
  @spec for_kind(binary(), atom()) :: map()
  def for_kind(customer_id, kind) do
    case Store.get_policy(customer_id, kind) do
      nil -> default(kind)
      p -> row(p)
    end
  end

  @doc "When a submission (or revision) at `now` approves itself (QP7-14), or `nil` when off."
  @spec auto_approve_at(binary(), atom(), DateTime.t()) :: DateTime.t() | nil
  def auto_approve_at(customer_id, kind, %DateTime{} = now) do
    case for_kind(customer_id, kind).auto_approve_hours do
      nil -> nil
      hours -> DateTime.add(now, hours * 3600, :second)
    end
  end

  @doc "The slots a policy makes (`[%{slot, user_id: nil}]`); none for `ad_hoc`."
  @spec slots(map()) :: [map()]
  def slots(%{needs: :customer}), do: [%{slot: :customer, user_id: nil}]
  def slots(%{needs: :team_lead}), do: [%{slot: :team_lead, user_id: nil}]

  def slots(%{needs: :both}),
    do: [%{slot: :customer, user_id: nil}, %{slot: :team_lead, user_id: nil}]

  def slots(%{needs: :ad_hoc}), do: []

  @doc "`GET /customers/:id/approval-policies`: the eight **policy rows**, in the kinds' order."
  @spec list(Scope.t(), term()) :: {:ok, [map()]} | {:error, term()}
  def list(%Scope{} = scope, customer_id) do
    with {:ok, customer} <- customer(scope, :read, customer_id) do
      stored = Map.new(Store.policies(customer.id), &{&1.approval_kind, &1})
      {:ok, Enum.map(@kinds, &((stored[&1] && row(stored[&1])) || default(&1)))}
    end
  end

  @doc """
  `PUT /customers/:id/approval-policies/:kind {needs, rule,
  auto_approve_hours}`: the override, audited. Answers the **policy row**.
  """
  @spec put(Scope.t(), term(), term(), map(), DateTime.t()) :: {:ok, map()} | {:error, term()}
  def put(%Scope{} = scope, customer_id, kind, params, %DateTime{} = now) do
    params = Leads.stringify(params)

    with {:ok, customer} <- customer(scope, :edit, customer_id),
         {:ok, kind} <- kind(kind),
         {:ok, needs} <- enum(params["needs"], [:customer, :team_lead, :both, :ad_hoc], :needs),
         {:ok, rule} <- enum(params["rule"], [:any, :all], :rule),
         {:ok, hours} <- hours(params["auto_approve_hours"]) do
      attrs = %{
        organisation_id: customer.organisation_id,
        customer_id: customer.id,
        approval_kind: kind,
        needs: needs,
        rule: rule,
        auto_approve_hours: hours,
        updated_by_user_id: Scope.user_id(scope)
      }

      Customers.commit(fn -> overridden(scope, attrs, now) end)
    end
  end

  defp overridden(scope, attrs, now) do
    before =
      Store.get_policy(attrs.customer_id, attrs.approval_kind) || default(attrs.approval_kind)

    with {:ok, p} <- Store.put_policy(attrs) do
      {:ok, _audit} =
        Audit.record(scope, "approval_policy_set", p,
          before: snapshot(before),
          after: snapshot(p),
          now: now
        )

      {:ok, row(p)}
    end
  end

  @doc "`DELETE /customers/:id/approval-policies/:kind`: back to the default. Answers `:ok`."
  @spec reset(Scope.t(), term(), term(), DateTime.t()) :: :ok | {:error, term()}
  def reset(%Scope{} = scope, customer_id, kind, %DateTime{} = now) do
    with {:ok, customer} <- customer(scope, :edit, customer_id),
         {:ok, kind} <- kind(kind) do
      reset_policy(scope, Store.get_policy(customer.id, kind), now)
    end
  end

  defp reset_policy(_scope, nil, _now), do: :ok

  defp reset_policy(scope, p, now) do
    with {:ok, _gone} <- Customers.commit(fn -> reset_one(scope, p, now) end), do: :ok
  end

  defp reset_one(scope, p, now) do
    {:ok, gone} = Store.delete_policy(p)

    {:ok, _audit} =
      Audit.record(scope, "approval_policy_reset", gone,
        before: snapshot(p),
        after: snapshot(default(p.approval_kind)),
        now: now
      )

    {:ok, gone}
  end

  defp customer(scope, action, id) do
    with %{} = customer <-
           Data.Customers.get(Scope.organisation_id(scope), to_string(id)) || {:error, :not_found},
         :ok <- Access.why_not(scope, action, {:approval_policy, %{customer: customer}}),
         do: {:ok, customer}
  end

  defp kind(kind) do
    case Enum.find(@kinds, &(to_string(&1) == to_string(kind))) do
      nil -> {:error, :not_found}
      kind -> {:ok, kind}
    end
  end

  defp enum(nil, _allowed, field), do: {:error, {:missing, [field]}}

  defp enum(value, allowed, field) do
    case Ask.pick(value, allowed) do
      nil -> Leads.invalid(to_string(field), "is one of #{Enum.join(allowed, ", ")}")
      atom -> {:ok, atom}
    end
  end

  defp hours(value) when value in @hours, do: {:ok, value}

  defp hours(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} -> hours(n)
      _bad -> hours(:bad)
    end
  end

  defp hours(_value), do: Leads.invalid("auto_approve_hours", "is off (null), 4, 12, 24 or 48")

  defp row(p) do
    %{
      approval_kind: p.approval_kind,
      needs: p.needs,
      rule: p.rule,
      auto_approve_hours: p.auto_approve_hours,
      is_default: false
    }
  end

  defp snapshot(p),
    do: %{
      "approval_kind" => to_string(p.approval_kind),
      "needs" => to_string(p.needs),
      "rule" => to_string(p.rule),
      "auto_approve_hours" => p.auto_approve_hours
    }
end
