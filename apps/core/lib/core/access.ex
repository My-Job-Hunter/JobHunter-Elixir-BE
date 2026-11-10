defmodule Core.Access do
  @moduledoc """
  Who may do what (JH-01 §5.2), **pure**: a scope, an action and a subject in,
  a decision out. No Repo, no clock.

  **A row the caller may not know exists is `:not_found`, never
  `:forbidden`** (AutoCare's rule): a team the caller is not in, a customer
  no team of theirs serves, another customer's profile from the portal —
  each answers as if it did not exist. A refusal on a subject the caller
  can see is words: the last admin, a lead reaching above lead (both raised
  by the contexts, which hold the counts), a member touching a pitch.

  ## Subjects

  | Subject | Carries |
  |---|---|
  | `{:organisation, org}` | — |
  | `{:team, team}` | `id` |
  | `{:invitation, inv}` | `kind`, `team_id`; `customer` for a customer invitation |
  | `{:customer, customer}` | `id`, `team_ids` (the teams serving them; `Data.Customers` fills it) |
  | `{:profile, profile}` · `{:channel, channel}` | `customer` as above |
  | `{:document, document}` | `profile` with its `customer` |
  | `{:skill, skill}` | — |
  | `:people` · `:self` | — |

  ## The matrix (§5.3), in one sentence per column

  An **admin** does everything. A **manager** does everything in their
  teams, and sees a customer in no team (QP1-8). A **lead** does everything
  in their team. A **member** reads their team's customers, notes and
  profiles, edits a profile's **facts** but not its **pitch** (QP1-7), and
  has full run of channels and documents. A **customer** reads and edits
  their own: contact details, pitch and facts, channels, documents — and
  nothing of anyone else's. `Core.AccessMatrixTest` asserts every cell.
  """

  alias Data.Scope

  @type action :: atom()
  @type subject ::
          {:organisation, map()}
          | {:team, map()}
          | {:invitation, map()}
          | {:customer, map()}
          | {:profile, map()}
          | {:channel, map()}
          | {:document, map()}
          | {:skill, map()}
          | :people
          | :self
  @type refusal :: {:error, :not_found | {:forbidden, String.t()}}

  @team_lead_actions [
    :read_settings,
    :update_settings,
    :invite_member,
    :change_role,
    :remove_member
  ]
  @team_manager_actions [:update, :archive | @team_lead_actions]

  @customer_lead_actions [:update, :change_status, :assign_team, :write_note, :invite]
  @profile_lead_actions [:create, :archive, :set_owners]
  @asset_actions [:read, :create, :update, :archive, :download]

  @pitch_words "The pitch is the customer's or a lead's to change."
  @lead_words "Only a lead or above can do that for a customer."

  @doc "Whether the caller may take `action` on `subject`."
  @spec can?(Scope.t(), action(), subject()) :: boolean()
  def can?(%Scope{} = scope, action, subject), do: decide(scope, action, subject) == :ok

  @doc "The refusal, as the API will answer it, or `:ok`."
  @spec why_not(Scope.t(), action(), subject()) :: :ok | refusal()
  def why_not(%Scope{} = scope, action, subject), do: decide(scope, action, subject)

  @doc "The words a member is refused a pitch with (§7.2)."
  def pitch_words, do: @pitch_words

  # The system acting on its own (`Data.Scope.system/1`: a mix task, a job)
  # answers to nobody; its audit rows say `via: system` with no actor.
  defp decide(%Scope{via: :system, user: nil}, _action, _subject), do: :ok

  # ── The organisation ────────────────────────────────────────────────────────

  defp decide(scope, :read_settings, {:organisation, _org}) do
    allow(
      Scope.admin?(scope) or Scope.any_team?(scope, :manager) or Scope.any_team?(scope, :lead),
      else: {:forbidden, "Only a lead or above can see the organisation's settings."}
    )
  end

  defp decide(scope, :read_audit, {:organisation, _org}) do
    allow(Scope.admin?(scope) or Scope.any_team?(scope, :manager),
      else: {:forbidden, "Only a manager or an admin can read the audit log."}
    )
  end

  defp decide(scope, action, {:organisation, _org})
       when action in [:update_settings, :list_admins, :grant_admin, :revoke_admin, :suspend_user] do
    allow(Scope.admin?(scope), else: {:forbidden, "Only an admin can do that."})
  end

  # ── Teams ───────────────────────────────────────────────────────────────────

  defp decide(scope, :create, {:team, _team}) do
    allow(Scope.admin?(scope) or Scope.any_team?(scope, :manager),
      else: {:forbidden, "Only a manager or an admin can create a team."}
    )
  end

  defp decide(scope, action, {:team, team}) do
    case {Scope.admin?(scope), Scope.team_role(scope, team.id)} do
      {true, _role} -> :ok
      {false, nil} -> {:error, :not_found}
      {false, role} -> team_action(action, role)
    end
  end

  # ── Invitations ─────────────────────────────────────────────────────────────

  defp decide(scope, :create, {:invitation, %{kind: :admin}}) do
    allow(Scope.admin?(scope), else: {:forbidden, "Only an admin can invite an admin."})
  end

  defp decide(scope, :create, {:invitation, %{kind: :team_member, team_id: team_id}}) do
    decide(scope, :invite_member, {:team, %{id: team_id}})
  end

  # A customer invitation is the customer's `:invite`: the same reach.
  defp decide(scope, :create, {:invitation, %{kind: :customer, customer: %{} = customer}}) do
    decide(scope, :invite, {:customer, customer})
  end

  defp decide(_scope, :create, {:invitation, %{kind: :customer}}), do: {:error, :not_found}

  defp decide(scope, :list, {:invitation, _any}) do
    allow(
      Scope.admin?(scope) or Scope.any_team?(scope, :manager) or Scope.any_team?(scope, :lead),
      else: {:forbidden, "Only a lead or above can see invitations."}
    )
  end

  defp decide(scope, action, {:invitation, invitation}) when action in [:read, :revoke] do
    cond do
      Scope.admin?(scope) -> :ok
      invitation.kind == :team_member -> team_invitation(scope, action, invitation.team_id)
      invitation.kind == :customer -> customer_invitation(scope, action, invitation)
      true -> {:error, :not_found}
    end
  end

  # ── Customers ───────────────────────────────────────────────────────────────

  # Every staff account lists customers; the context narrows the list to
  # the teams the caller is in. A customer (the portal) has no list.
  defp decide(scope, :list, {:customer, _any}) do
    allow(Scope.staff?(scope), else: {:error, :not_found})
  end

  defp decide(scope, :create, {:customer, _new}) do
    allow(
      Scope.admin?(scope) or Scope.any_team?(scope, :manager) or Scope.any_team?(scope, :lead),
      else: {:forbidden, "Only a lead or above can add a customer."}
    )
  end

  defp decide(scope, action, {:customer, customer}) do
    customer_action(action, reach(scope, customer))
  end

  # ── Profiles, channels, documents: the customer's reach decides ─────────────

  defp decide(scope, action, {:profile, %{customer: customer}}) do
    profile_action(action, reach(scope, customer))
  end

  defp decide(scope, action, {:channel, %{customer: customer}}) when action in @asset_actions do
    asset_action(reach(scope, customer))
  end

  defp decide(scope, action, {:document, %{profile: %{customer: customer}}})
       when action in @asset_actions do
    asset_action(reach(scope, customer))
  end

  # ── Skills: the vocabulary ──────────────────────────────────────────────────

  # Everyone signed in reads it (the portal edits a profile's skills); staff
  # add to it; a lead or above archives.
  defp decide(scope, :read, {:skill, _skill}) do
    allow(Scope.staff?(scope) or Scope.customer?(scope), else: {:error, :not_found})
  end

  defp decide(scope, :create, {:skill, _skill}) do
    cond do
      Scope.staff?(scope) -> :ok
      Scope.customer?(scope) -> {:error, {:forbidden, "Ask your team to add a skill."}}
      true -> {:error, :not_found}
    end
  end

  defp decide(scope, :archive, {:skill, _skill}) do
    cond do
      Scope.admin?(scope) or Scope.any_team?(scope, :manager) or Scope.any_team?(scope, :lead) ->
        :ok

      Scope.staff?(scope) ->
        {:error, {:forbidden, "Only a lead or above can retire a skill."}}

      true ->
        {:error, :not_found}
    end
  end

  # ── People and self ─────────────────────────────────────────────────────────

  # Every staff account sees the staff list; the context narrows it to the
  # caller's own teams. A customer does not: for the portal there is no list.
  defp decide(scope, :read_people, :people) do
    allow(Scope.staff?(scope), else: {:error, :not_found})
  end

  defp decide(%Scope{user: %{id: _id}}, action, :self) when action in [:read_self, :update_self],
    do: :ok

  defp decide(_scope, _action, _subject), do: {:error, :not_found}

  # ── Reach: how far the caller gets to a customer ────────────────────────────

  # `:admin`; `{:staff, role}` with the strongest role the caller holds in a
  # team serving the customer (a manager anywhere reaches a customer in no
  # team, QP1-8); `:self` for the customer themselves; `:none` otherwise.
  defp reach(scope, %{id: id, team_ids: team_ids}) do
    cond do
      Scope.admin?(scope) -> :admin
      Scope.customer_id(scope) == id -> :self
      team_ids == [] and Scope.any_team?(scope, :manager) -> {:staff, :manager}
      true -> staff_reach(Scope.role_in_any(scope, team_ids))
    end
  end

  defp staff_reach(nil), do: :none
  defp staff_reach(role), do: {:staff, role}

  defp customer_action(_action, :none), do: {:error, :not_found}
  defp customer_action(_action, :admin), do: :ok
  defp customer_action(:read, _reach), do: :ok

  defp customer_action(action, {:staff, role}) when action in @customer_lead_actions,
    do: lead_or_above(role)

  defp customer_action(:read_notes, {:staff, _role}), do: :ok
  defp customer_action(:update, :self), do: :ok
  defp customer_action(:read_notes, :self), do: {:error, :not_found}

  defp customer_action(action, :self) when action in @customer_lead_actions,
    do: {:error, {:forbidden, "That is for the team serving you to do."}}

  defp customer_action(_action, _reach), do: {:error, :not_found}

  defp profile_action(_action, :none), do: {:error, :not_found}
  defp profile_action(_action, :admin), do: :ok
  defp profile_action(action, _reach) when action in [:read, :update_facts], do: :ok
  defp profile_action(:update_pitch, {:staff, :member}), do: {:error, {:forbidden, @pitch_words}}
  defp profile_action(:update_pitch, _reach), do: :ok

  defp profile_action(action, {:staff, role}) when action in @profile_lead_actions,
    do: lead_or_above(role)

  defp profile_action(:create, :self),
    do: {:error, {:forbidden, "Your team sets up your profiles; you edit them."}}

  defp profile_action(action, :self) when action in @profile_lead_actions,
    do: {:error, {:forbidden, "That is for the team serving you to do."}}

  defp profile_action(_action, _reach), do: {:error, :not_found}

  defp asset_action(:none), do: {:error, :not_found}
  defp asset_action(_reach), do: :ok

  defp lead_or_above(:member), do: {:error, {:forbidden, @lead_words}}
  defp lead_or_above(_lead_or_manager), do: :ok

  # ── Helpers ─────────────────────────────────────────────────────────────────

  # What each role may do inside its own team (§5.3, the Teams row).
  defp team_action(action, _role) when action in [:read, :list_members], do: :ok
  defp team_action(action, :manager) when action in @team_manager_actions, do: :ok
  defp team_action(action, :lead) when action in @team_lead_actions, do: :ok

  defp team_action(action, :lead) when action in [:update, :archive],
    do: {:error, {:forbidden, "Only a manager or an admin can change the team itself."}}

  defp team_action(_action, :member),
    do: {:error, {:forbidden, "Only a lead or above can do that in this team."}}

  defp team_action(_action, _role), do: {:error, {:forbidden, "You cannot do that in this team."}}

  # Reading or revoking an invitation follows the right to issue one; whoever
  # lacks it cannot list invitations either, so the row is not found.
  defp team_invitation(scope, _action, team_id) do
    case decide(scope, :invite_member, {:team, %{id: team_id}}) do
      :ok -> :ok
      {:error, _refusal} -> {:error, :not_found}
    end
  end

  defp customer_invitation(_scope, _action, %{customer: nil}), do: {:error, :not_found}

  defp customer_invitation(scope, _action, %{customer: customer}) do
    case decide(scope, :invite, {:customer, customer}) do
      :ok -> :ok
      {:error, _refusal} -> {:error, :not_found}
    end
  end

  defp allow(true, _else), do: :ok
  defp allow(false, else: {:error, _reason} = error), do: error
  defp allow(false, else: reason), do: {:error, reason}
end
