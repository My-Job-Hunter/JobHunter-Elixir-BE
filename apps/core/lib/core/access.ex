defmodule Core.Access do
  @moduledoc """
  Who may do what (AQ-01 §5.2; AQ-04A §4.0 and §8.5 for the roles), **pure**:
  a scope, an action and a subject in, a decision out. No Repo, no clock.

  **A row the caller may not know exists is `:not_found`, never
  `:forbidden`** (mCart's rule): a team the caller is not in, a customer
  no team of theirs serves, another customer's profile from the portal —
  each answers as if it did not exist. A refusal on a subject the caller
  can see is words: a team lead removing another lead (raised by the
  context, which holds the membership), a member touching a pitch.

  ## Subjects

  | Subject | Carries |
  |---|---|
  | `{:organisation, org}` | — |
  | `{:team, team}` | `id` |
  | `{:invitation, inv}` | `kind`, `team_id`; `customer` for a customer invitation |
  | `{:customer, customer}` | `id`, `team_ids` (the teams serving them; `Data.Customers` fills it) |
  | `{:profile, profile}` · `{:channel, channel}` | `customer` as above; a channel's `:renew_address` also `owner_user_ids` (AQ-09 §4) |
  | `{:document, document}` | `profile` with its `customer` |
  | `{:skill, skill}` | — |
  | `{:task, task}` | `author_user_id`, `team_id`, `customer_id`, `customer_access`, `state`, `source`, `archived_at`, `participants`, `steps` (AQ-02 §6; decided by `Core.Access.Tasks`) |
  | `{:job, job}` | `organisation_id`, `team_id`, `created_by_user_id` (AQ-03 §4, AQ-03B §3.2; decided by `Core.Access.Jobs`) |
  | `{:company, company}` | `organisation_id` (decided by `Core.Access.Jobs`) |
  | `{:lead, lead}` | `organisation_id`, `team_id` (the job's), `owner_user_id`, `applied_by_user_id`, `customer_id`, `state`, `archived_at` (AQ-04A §4; decided by `Core.Access.Leads`; AQ-04B adds `:note`, `:follow_up`, `:label`, `:add_task`) |
  | `{:lead_note, note}` | `author_user_id`, `lead` (the lead's subject) (AQ-04B §4) |
  | `{:label, label}` | `organisation_id`, `team_id`: `:read`, `:manage` (AQ-04B §4) |
  | `{:saved_view, view}` | `user_id`: its owner's alone (AQ-04B §4) |
  | `{:retention, team}` | `team_id`: `:preview`, the system admin's and the team's leads' (AQ-04B QP4b-7) |
  | `{:contact, c}` · `{:conversation, c}` · `{:message, m}` · `{:meeting, m}` | AQ-06 §4, decided by `Core.Access.Conversations` on their leads |
  | `{:approval, a}` · `{:approval_request, r}` · `{:approval_comment, c}` · `{:approval_policy, p}` | AQ-07 §4, decided by `Core.Access.Approvals` (an approval on a lead by P4a's rules) |
  | `{:pipeline, key}` | — (AQ-04A §4.2: the organisation's) |
  | `{:share_link, link}` | `organisation_id`, `created_by_user_id`, `team_id` (the item's team; AQ-03B §3.3) |
  | `:extension` | — (AQ-05 §4: `:connect`, `:use`, `:report_misses` for staff; `:list_devices`, `:read_health`, `:read_configs` the system admin's) |
  | `{:device, device}` | `organisation_id`, `user_id`: `:read`, `:disconnect` (AQ-05 §4) |
  | `:people` · `:self` | — |

  ## The matrix, in one sentence per chair (AQ-04A §4.0)

  The **system admin** does everything, in every team, and sees a customer
  in no team (QP4a-23). A **team lead** does everything in their team — its
  settings and levels, its members (staff, never another lead), its
  customers — but makes no team, no team lead and no change to the system.
  **Staff** (`member`) read their team's customers, notes and profiles,
  edit a profile's **facts** but not its **pitch** (QP1-7), and have full
  run of channels and documents. A **customer** reads and edits their own:
  contact details, pitch and facts, channels, documents — and nothing of
  anyone else's. `Core.AccessMatrixTest` asserts every cell,
  `Core.TaskAccessMatrixTest` the task rows of AQ-02 §6.3,
  `Core.JobAccessMatrixTest` the job and company rows of AQ-03 §4.3 and
  `Core.LeadAccessMatrixTest` the lead rows of AQ-04A §4.3,
  `Core.ExtensionAccessMatrixTest` the extension's of AQ-05 §4, and
  `Core.ConversationAccessMatrixTest` and `Core.MeetingAccessMatrixTest`
  AQ-06 §4's, and `Core.ApprovalAccessMatrixTest` AQ-07 §4's.

  **The extension acts as the person who connected it** (AQ-05 QP5-6):
  their own scope, with `via: :extension`, decided here exactly as in the
  console. Only connecting, the devices and the extension's health are
  rows of their own.
  """

  alias Core.Access.Approvals
  alias Core.Access.Channels
  alias Core.Access.Conversations
  alias Core.Access.Jobs
  alias Core.Access.Leads
  alias Core.Access.Tasks
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
          | {:task, map()}
          | {:job, map()}
          | {:company, map()}
          | {:lead, map()}
          | {:lead_note, map()}
          | {:label, map()}
          | {:saved_view, map()}
          | {:retention, map()}
          | {:contact, map()}
          | {:conversation, map()}
          | {:message, map()}
          | {:meeting, map()}
          | {:approval, map()}
          | {:approval_request, map()}
          | {:approval_comment, map()}
          | {:approval_policy, map()}
          | {:pipeline, term()}
          | {:share_link, map()}
          | :extension
          | {:device, map()}
          | :people
          | :self
  @type refusal :: {:error, :not_found | :not_reviewer | {:forbidden, String.t()}}

  @team_lead_actions [:read_settings, :update_settings, :invite_member, :remove_member]
  @admin_team_actions [:update, :archive, :change_role]

  @customer_lead_actions [:update, :change_status, :write_note, :invite]
  @profile_lead_actions [:create, :archive, :set_owners]
  @asset_actions [:read, :create, :update, :archive, :download]

  @admin_words "Only the system admin can do that."
  @customer_team_words "Only a lead of that team can add a customer to it."
  @pipeline_words "Only a team lead can change a pipeline."
  @pitch_words "The pitch is the customer's or a lead's to change."
  @lead_words "Only a team lead can do that for a customer."
  @share_words "Only whoever made this link, or a team lead, can turn it off."

  @doc "Whether the caller may take `action` on `subject`."
  @spec can?(Scope.t(), action(), subject()) :: boolean()
  def can?(%Scope{} = scope, action, subject), do: decide(scope, action, subject) == :ok

  @doc "The refusal, as the API will answer it, or `:ok`."
  @spec why_not(Scope.t(), action(), subject()) :: :ok | refusal()
  def why_not(%Scope{} = scope, action, subject), do: decide(scope, action, subject)

  @doc "The words a member is refused a pitch with (§7.2)."
  def pitch_words, do: @pitch_words

  @doc "The words for what only the system admin does (AQ-04A §8.5)."
  def admin_words, do: @admin_words

  @doc "The words for a customer put in a team the caller does not lead (AQ-04A §8.5)."
  def customer_team_words, do: @customer_team_words

  # The system acting on its own (`Data.Scope.system/1`: a mix task, a job)
  # answers to nobody; its audit rows say `via: system` with no actor.
  defp decide(%Scope{via: :system, user: nil}, _action, _subject), do: :ok

  # ── The organisation: *Settings › System*, the system admin's alone ────────

  defp decide(scope, action, {:organisation, _org})
       when action in [:read_settings, :update_settings, :read_audit, :suspend_user] do
    allow(Scope.admin?(scope), else: {:forbidden, @admin_words})
  end

  # ── Teams ───────────────────────────────────────────────────────────────────

  defp decide(scope, :create, {:team, _team}) do
    allow(Scope.admin?(scope), else: {:forbidden, @admin_words})
  end

  defp decide(scope, action, {:team, team}) do
    case {Scope.admin?(scope), Scope.team_role(scope, team.id)} do
      {true, _role} -> :ok
      {false, nil} -> {:error, :not_found}
      {false, role} -> team_action(action, role)
    end
  end

  # ── Invitations ─────────────────────────────────────────────────────────────

  # The bootstrap issues the one admin invitation, as the system; nobody else.
  defp decide(_scope, :create, {:invitation, %{kind: :admin}}),
    do: {:error, {:forbidden, @admin_words}}

  defp decide(scope, :create, {:invitation, %{kind: :team_member, team_id: team_id}}) do
    decide(scope, :invite_member, {:team, %{id: team_id}})
  end

  # A customer invitation is the customer's `:invite`: the same reach.
  defp decide(scope, :create, {:invitation, %{kind: :customer, customer: %{} = customer}}) do
    decide(scope, :invite, {:customer, customer})
  end

  defp decide(_scope, :create, {:invitation, %{kind: :customer}}), do: {:error, :not_found}

  defp decide(scope, :list, {:invitation, _any}) do
    allow(Scope.admin?(scope) or Scope.any_team?(scope, :lead),
      else: {:forbidden, "Only a team lead can see invitations."}
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

  # A team lead adds a customer straight into a team they lead (the context
  # checks each team); the system admin into any.
  defp decide(scope, :create, {:customer, _new}) do
    allow(Scope.admin?(scope) or Scope.any_team?(scope, :lead),
      else: {:forbidden, @customer_team_words}
    )
  end

  # Another team for a customer the caller reaches: a lead (of the team
  # named, which the context checks) or the system admin (AQ-04A §8.5).
  defp decide(scope, :assign_team, {:customer, customer}) do
    case reach(scope, customer) do
      :none -> {:error, :not_found}
      :admin -> :ok
      :self -> {:error, {:forbidden, "That is for the team serving you to do."}}
      {:staff, _role} -> allow(Scope.any_team?(scope, :lead), else: {:forbidden, @lead_words})
    end
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

  # *New address* (AQ-09 §4): `Core.Access.Channels` decides on the reach.
  defp decide(scope, :renew_address, {:channel, %{customer: customer} = channel}),
    do: Channels.renew_address(scope, channel, reach(scope, customer))

  defp decide(scope, action, {:document, %{profile: %{customer: customer}}})
       when action in @asset_actions do
    asset_action(reach(scope, customer))
  end

  # ── Skills: the vocabulary ──────────────────────────────────────────────────

  # Everyone signed in reads it (the portal edits a profile's skills); staff
  # add to it; a team lead or the system admin archives.
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
      Scope.admin?(scope) or Scope.any_team?(scope, :lead) -> :ok
      Scope.staff?(scope) -> {:error, {:forbidden, "Only a team lead can retire a skill."}}
      true -> {:error, :not_found}
    end
  end

  # ── Tasks (AQ-02 §6): `Core.Access.Tasks` holds the rows ─────────────────────

  # Any staff, on a team they are in (any team for an admin; AQ-03B: every
  # task is in a team); the customer through the portal (§9).
  defp decide(scope, :create, {:task, %{team_id: team_id}}) do
    cond do
      Scope.customer?(scope) -> :ok
      not Scope.staff?(scope) -> {:error, :not_found}
      Scope.admin?(scope) -> :ok
      is_binary(team_id) and Scope.team_role(scope, team_id) -> :ok
      true -> {:error, :not_found}
    end
  end

  defp decide(scope, action, {:task, task}), do: Tasks.decide(scope, action, task)

  # ── The job pool (AQ-03 §4): `Core.Access.Jobs` holds the rows ──────────────

  defp decide(scope, action, {kind, _subject} = subject) when kind in [:job, :company],
    do: Jobs.decide(scope, action, subject)

  # ── Leads (AQ-04A §4): `Core.Access.Leads` holds the rows ───────────────────

  defp decide(scope, action, {:lead, lead}), do: Leads.decide(scope, action, lead)

  # AQ-04B §4: a note on a lead, a team's labels, a person's saved views,
  # Settings › Retention.
  defp decide(scope, action, {:lead_note, note}), do: Leads.decide_note(scope, action, note)
  defp decide(scope, action, {:label, label}), do: Leads.decide_label(scope, action, label)
  defp decide(scope, :preview, {:retention, team}), do: Leads.decide_retention(scope, team)

  defp decide(scope, _action, {:saved_view, view}) do
    allow(not is_nil(Scope.user_id(scope)) and view.user_id == Scope.user_id(scope),
      else: {:error, :not_found}
    )
  end

  # ── Contacts, conversations, meetings (AQ-06 §4) ───────────────────────────

  defp decide(scope, action, {:contact, c}), do: Conversations.decide_contact(scope, action, c)

  defp decide(scope, action, {:conversation, c}),
    do: Conversations.decide_conversation(scope, action, c)

  defp decide(scope, action, {:message, m}), do: Conversations.decide_message(scope, action, m)
  defp decide(scope, action, {:meeting, m}), do: Conversations.decide_meeting(scope, action, m)

  # ── Approvals (AQ-07 §4): `Core.Access.Approvals` holds the rows ───────────

  defp decide(scope, action, {:approval, a}), do: Approvals.decide(scope, action, a)
  defp decide(scope, :create, {:approval_request, r}), do: Approvals.decide_request(scope, r)

  defp decide(scope, action, {:approval_comment, c}),
    do: Approvals.decide_comment(scope, action, c)

  defp decide(scope, action, {:approval_policy, p}), do: Approvals.decide_policy(scope, action, p)

  # ── Pipelines (AQ-04A §4.2, QP4a-2): the organisation's ─────────────────────

  defp decide(scope, :read, {:pipeline, _key}) do
    allow(Scope.staff?(scope) and not Scope.customer?(scope), else: {:error, :not_found})
  end

  defp decide(scope, :edit, {:pipeline, _key}) do
    cond do
      not Scope.staff?(scope) or Scope.customer?(scope) -> {:error, :not_found}
      Scope.admin?(scope) or Scope.any_team?(scope, :lead) -> :ok
      true -> {:error, {:forbidden, @pipeline_words}}
    end
  end

  # ── Share links (AQ-03B §3.3) ───────────────────────────────────────────────

  # Opening: any signed-in staff of the organisation; a customer, or anyone
  # of another organisation, finds nothing.
  defp decide(scope, :open, {:share_link, link}) do
    allow(
      Scope.staff?(scope) and not Scope.customer?(scope) and
        link.organisation_id == Scope.organisation_id(scope),
      else: {:error, :not_found}
    )
  end

  # Turning one off: its maker, a lead of the item's team, the system admin.
  defp decide(scope, :revoke, {:share_link, link}) do
    cond do
      not Scope.staff?(scope) or Scope.customer?(scope) -> {:error, :not_found}
      link.organisation_id != Scope.organisation_id(scope) -> {:error, :not_found}
      Scope.admin?(scope) -> :ok
      link.created_by_user_id == Scope.user_id(scope) -> :ok
      Scope.team_role(scope, link.team_id) == :lead -> :ok
      true -> {:error, {:forbidden, @share_words}}
    end
  end

  # ── The extension (AQ-05 §4) ────────────────────────────────────────────────

  # Minting a connect code, any `/ext/v1` route, reporting misses: a staff
  # account. A customer never connects (the portal has no such route).
  defp decide(scope, action, :extension) when action in [:connect, :use, :report_misses] do
    allow(Scope.staff?(scope) and not Scope.customer?(scope), else: {:error, :not_found})
  end

  # Every device, the health page, the configs: the system admin's alone.
  defp decide(scope, action, :extension)
       when action in [:list_devices, :read_health, :read_configs] do
    allow(Scope.admin?(scope), else: {:error, :not_found})
  end

  # One's own device, or any for the system admin; nobody else's exists.
  defp decide(scope, action, {:device, device}) when action in [:read, :disconnect] do
    allow(
      device.organisation_id == Scope.organisation_id(scope) and
        (Scope.admin?(scope) or device.user_id == Scope.user_id(scope)),
      else: {:error, :not_found}
    )
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

  # `:admin` (who alone reaches a customer in no team, QP4a-23); `{:staff,
  # role}` with the strongest role the caller holds in a team serving the
  # customer; `:self` for the customer themselves; `:none` otherwise.
  defp reach(scope, %{id: id, team_ids: team_ids}) do
    cond do
      Scope.admin?(scope) -> :admin
      Scope.customer_id(scope) == id -> :self
      true -> staff_reach(Scope.role_in_any(scope, team_ids))
    end
  end

  defp staff_reach(nil), do: :none
  defp staff_reach(role), do: {:staff, role}

  defp customer_action(_action, :none), do: {:error, :not_found}
  defp customer_action(_action, :admin), do: :ok
  defp customer_action(:read, _reach), do: :ok

  defp customer_action(action, {:staff, role}) when action in @customer_lead_actions,
    do: lead(role)

  defp customer_action(:read_notes, {:staff, _role}), do: :ok
  defp customer_action(:update, :self), do: :ok
  defp customer_action(:read_notes, :self), do: {:error, :not_found}

  defp customer_action(action, :self) when action in @customer_lead_actions,
    do: {:error, {:forbidden, "That is for the team serving you to do."}}

  # Customer › Activity (AQ-04B QP4b-22): a team lead, their teams' rows;
  # staff find nothing (the system admin passed above).
  defp customer_action(:read_activity, {:staff, :lead}), do: :ok

  defp customer_action(_action, _reach), do: {:error, :not_found}

  defp profile_action(_action, :none), do: {:error, :not_found}
  defp profile_action(_action, :admin), do: :ok
  defp profile_action(action, _reach) when action in [:read, :update_facts], do: :ok
  defp profile_action(:update_pitch, {:staff, :member}), do: {:error, {:forbidden, @pitch_words}}
  defp profile_action(:update_pitch, _reach), do: :ok

  defp profile_action(action, {:staff, role}) when action in @profile_lead_actions,
    do: lead(role)

  defp profile_action(:create, :self),
    do: {:error, {:forbidden, "Your team sets up your profiles; you edit them."}}

  defp profile_action(action, :self) when action in @profile_lead_actions,
    do: {:error, {:forbidden, "That is for the team serving you to do."}}

  defp profile_action(_action, _reach), do: {:error, :not_found}

  defp asset_action(:none), do: {:error, :not_found}
  defp asset_action(_reach), do: :ok

  defp lead(:lead), do: :ok
  defp lead(_member), do: {:error, {:forbidden, @lead_words}}

  # ── Helpers ─────────────────────────────────────────────────────────────────

  # What each role may do inside its own team (§8.5): a team lead runs the
  # team's settings, invitations and staff; the team itself and its roles
  # are the system admin's.
  defp team_action(action, _role) when action in [:read, :list_members], do: :ok
  defp team_action(action, :lead) when action in @team_lead_actions, do: :ok

  defp team_action(action, _role) when action in @admin_team_actions,
    do: {:error, {:forbidden, @admin_words}}

  defp team_action(_action, :member),
    do: {:error, {:forbidden, "Only a team lead can do that in this team."}}

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
