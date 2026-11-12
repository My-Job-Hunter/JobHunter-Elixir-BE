defmodule Core.Access.Approvals do
  @moduledoc """
  Who sees, asks, decides and changes an approval (AQ-07 §4), **pure**: the
  `{:approval, _}`, `{:approval_request, _}`, `{:approval_comment, _}` and
  `{:approval_policy, _}` rows of `Core.Access`. An approval on a lead is
  read by whoever reads the lead (P4a's rules, the team's `peer_leads`):
  one rulebook.

  | Subject | Carries |
  |---|---|
  | `{:approval, a}` | `organisation_id`, `team_id`, `customer_id`, `state`, `requested_by_user_id`, `slots` (`[%{slot, user_id}]`), `lead` (the lead's subject, or `nil`) |
  | `{:approval_request, r}` | `approval_kind`, `lead` (subject) or `profile` (with its `customer`) |
  | `{:approval_comment, c}` | `author_user_id`, `approval` (as above) |
  | `{:approval_policy, p}` | `customer` (`id`, `team_ids`) |

  - **Seeing** (QP7-17): the requester; its reviewers (a named person; any
    lead of the team for a *team lead* slot); the team's leads; the system
    admin; a member who reads its lead, by `peer_leads`. A **draft** is the
    requester's, the team's leads' and the system admin's alone. **The
    customer** sees an approval about them that holds a customer slot, once
    it is submitted; never a staff-only one, never another customer's.
    Anyone else finds nothing (`:not_found`).
  - **Asking** (QP7-2): on a lead, whoever may change it
    (`:request_approval`, P4a's words); a `profile_change`, any staff of a
    team serving the customer (else not found). Customers don't ask.
  - **Deciding** (QP7-4): a reviewer — the customer for a customer slot, a
    lead of the team for a *team lead* slot, a named person for theirs —
    and never whoever asked; anyone else who sees it is `:not_reviewer`
    ("This isn't yours to decide."). Whether a slot is still open, and the
    version, are the verb's (409 `approval_not_pending`).
  - **Changing** (edit, submit, revise, withdraw, *Recorded as sent*): the
    requester, a lead of the team, the system admin: "Only whoever asked,
    or a team lead, can change this." **Commenting:** whoever sees it.
    **A comment** is deleted by its author or a team lead.
  - **Policies** (QP7-16): read by whoever reads the customer; changed by a
    lead of a team serving them or the system admin: "Only a team lead can
    change approval rules."
  """

  alias Core.Access.Leads
  alias Data.Scope

  @change_actions [:edit, :submit, :revise, :withdraw, :sent]

  @change_words "Only whoever asked, or a team lead, can change this."
  @comment_words "Only its author or a team lead can delete this comment."
  @policy_words "Only a team lead can change approval rules."
  @team_words "That is for the team serving you to do."

  @doc "Every action an approval answers, for the matrix."
  def actions, do: [:read, :decide, :comment | @change_actions]

  @doc "The verbs that change an approval (§4's *revise, withdraw* row)."
  def change_actions, do: @change_actions

  @doc "The words for a change by anyone but the requester or a team lead."
  def change_words, do: @change_words

  @doc "The words for a policy changed by staff who are not a team lead."
  def policy_words, do: @policy_words

  # ── An approval ─────────────────────────────────────────────────────────────

  @spec decide(Scope.t(), atom(), map()) :: :ok | {:error, term()}
  def decide(%Scope{} = scope, action, approval) do
    case read(scope, approval) do
      :ok -> act(scope, action, approval)
      refusal -> refusal
    end
  end

  defp read(scope, a) do
    cond do
      not same_organisation?(scope, a) -> {:error, :not_found}
      Scope.customer?(scope) -> customer_reads(scope, a)
      Scope.staff?(scope) -> staff_reads(scope, a)
      true -> {:error, :not_found}
    end
  end

  # A draft is the requester's, the leads' and the admin's; once asked, a
  # named person's and whoever reads its lead's too.
  defp staff_reads(scope, a) do
    own? = Scope.admin?(scope) or lead_of?(scope, a.team_id) or requester?(scope, a)
    if own? or (a.state != :draft and asked_reads?(scope, a)), do: :ok, else: {:error, :not_found}
  end

  defp asked_reads?(scope, a),
    do: named?(scope, a) or (is_map(a.lead) and Leads.decide(scope, :read, a.lead) == :ok)

  defp customer_reads(scope, a) do
    if a.customer_id == Scope.customer_id(scope) and a.state != :draft and customer_slot?(a),
      do: :ok,
      else: {:error, :not_found}
  end

  defp act(_scope, action, _a) when action in [:read, :comment], do: :ok

  defp act(scope, :decide, a) do
    cond do
      Scope.customer?(scope) -> :ok
      requester?(scope, a) -> {:error, :not_reviewer}
      named?(scope, a) -> :ok
      team_lead_slot?(a) and lead_of?(scope, a.team_id) -> :ok
      true -> {:error, :not_reviewer}
    end
  end

  defp act(scope, action, a) when action in @change_actions do
    cond do
      Scope.customer?(scope) -> {:error, {:forbidden, @team_words}}
      Scope.admin?(scope) or lead_of?(scope, a.team_id) or requester?(scope, a) -> :ok
      true -> {:error, {:forbidden, @change_words}}
    end
  end

  defp act(_scope, _action, _a), do: {:error, :not_found}

  @doc """
  Whether the caller holds an open slot among `open_slots` (`[%{slot,
  user_id}]`) of `approval` — *Waiting on me* — and may decide it.
  """
  @spec waiting_on?(Scope.t(), map(), [map()]) :: boolean()
  def waiting_on?(%Scope{} = scope, approval, open_slots) do
    cond do
      decide(scope, :decide, approval) != :ok -> false
      Scope.customer?(scope) -> Enum.any?(open_slots, &(&1.slot == :customer))
      true -> Enum.any?(open_slots, &mine?(scope, approval, &1))
    end
  end

  @doc "Whether `slot` (`%{slot, user_id}`) is one the caller (staff) may take."
  @spec mine?(Scope.t(), map(), map()) :: boolean()
  def mine?(%Scope{} = scope, approval, %{slot: slot} = s) do
    case slot do
      :user -> s.user_id == Scope.user_id(scope)
      :team_lead -> lead_of?(scope, approval.team_id)
      :customer -> Scope.customer_id(scope) == approval.customer_id
    end
  end

  # ── Asking ──────────────────────────────────────────────────────────────────

  @spec decide_request(Scope.t(), map()) :: :ok | {:error, term()}
  def decide_request(%Scope{} = scope, %{approval_kind: :profile_change, profile: profile}) do
    cond do
      Scope.customer?(scope) or not Scope.staff?(scope) -> {:error, :not_found}
      Scope.admin?(scope) -> :ok
      Scope.role_in_any(scope, profile.customer.team_ids) -> :ok
      true -> {:error, :not_found}
    end
  end

  def decide_request(%Scope{} = scope, %{lead: %{} = lead}) do
    cond do
      Scope.customer?(scope) -> {:error, :not_found}
      Leads.decide(scope, :read, lead) != :ok -> {:error, :not_found}
      true -> Leads.decide(scope, :request_approval, lead)
    end
  end

  def decide_request(_scope, _request), do: {:error, :not_found}

  # ── A comment ───────────────────────────────────────────────────────────────

  @spec decide_comment(Scope.t(), atom(), map()) :: :ok | {:error, term()}
  def decide_comment(%Scope{} = scope, :delete, %{approval: approval} = comment) do
    with :ok <- read(scope, approval) do
      cond do
        not is_nil(comment.author_user_id) and comment.author_user_id == Scope.user_id(scope) ->
          :ok

        Scope.customer?(scope) ->
          {:error, {:forbidden, @comment_words}}

        Scope.admin?(scope) or lead_of?(scope, approval.team_id) ->
          :ok

        true ->
          {:error, {:forbidden, @comment_words}}
      end
    end
  end

  def decide_comment(_scope, _action, _comment), do: {:error, :not_found}

  # ── Policies ────────────────────────────────────────────────────────────────

  @spec decide_policy(Scope.t(), atom(), map()) :: :ok | {:error, term()}
  def decide_policy(%Scope{} = scope, action, %{customer: customer}) do
    case {action, policy_reach(scope, customer)} do
      {_action, :none} -> {:error, :not_found}
      {_action, :admin} -> :ok
      {:read, _role} -> :ok
      {:edit, :lead} -> :ok
      {:edit, :member} -> {:error, {:forbidden, @policy_words}}
      _other -> {:error, :not_found}
    end
  end

  defp policy_reach(scope, customer) do
    cond do
      Scope.customer?(scope) -> :none
      Scope.admin?(scope) -> :admin
      true -> Scope.role_in_any(scope, customer.team_ids || []) || :none
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────────────────

  defp requester?(scope, a),
    do: not is_nil(a.requested_by_user_id) and a.requested_by_user_id == Scope.user_id(scope)

  defp named?(scope, a),
    do: Enum.any?(a.slots, &(&1.slot == :user and &1.user_id == Scope.user_id(scope)))

  defp customer_slot?(a), do: Enum.any?(a.slots, &(&1.slot == :customer))
  defp team_lead_slot?(a), do: Enum.any?(a.slots, &(&1.slot == :team_lead))

  defp lead_of?(scope, team_id), do: Scope.team_role(scope, team_id) == :lead

  defp same_organisation?(scope, %{organisation_id: org_id}) when is_binary(org_id),
    do: org_id == Scope.organisation_id(scope)

  defp same_organisation?(_scope, _subject), do: true
end
