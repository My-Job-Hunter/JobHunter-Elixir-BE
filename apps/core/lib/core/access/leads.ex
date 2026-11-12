defmodule Core.Access.Leads do
  @moduledoc """
  Who sees and does what to a lead (AQ-04A §4.1, §4.2), **pure**: the
  `{:lead, lead}` rows of `Core.Access`.

  **A lead is in its job's team** (QP4a-8). The subject carries
  `organisation_id`, `team_id` (the job's), `owner_user_id`,
  `applied_by_user_id`, `customer_id` (the profile's customer), `state` and
  `archived_at` (`Core.Leads.subject/1` builds it). "Own" is the owner or
  whoever applied.

  **Seeing:** the system admin, every lead; a lead of its team, every lead
  of the team; a member of its team, their own, and a teammate's by the
  team's `peer_leads` (`hidden` not found, `view` read-only, `edit` as
  their own); anyone else, nothing (`:not_found`; a share link is
  `Core.ShareLinks`'). The customer sees their own leads, from every team.

  **Changing** (§4.2): the verbs that move or edit are the owner's, a member
  at `edit`'s, a team lead's and the system admin's; at `view`: "You can see
  this, but only its owner or a team lead can change it." Handing it on is
  the owner's (to someone in the team) or a lead's: "Only the owner or a team
  lead can hand this lead on." Archive and pin are the owner's or a lead's:
  "Only the lead's owner, or a team lead, can archive or pin it." Sharing is
  whoever sees it. The customer says *I applied* on their own lead in To do,
  and does nothing else to it.

  AQ-06 §4 adds two changes of the same rule: `:converse` (log a message,
  upload an `.eml`, link a contact, classify, link a conversation) and
  `:meet` (schedule, reschedule, cancel or finish a meeting), refused at
  `view` with the view-only words; AQ-07 §4 a third, `:request_approval`
  (draft or submit an approval on the lead).

  **A lead not made yet** (no `id`) is decided on its team and customer: a
  member of the job's team (or the system admin), for a customer the team
  serves: "Backend squad doesn't serve Imran."
  """

  alias Data.Scope

  @change_actions [
    :apply,
    :move,
    :hold,
    :resume,
    :finish,
    :reopen,
    :apply_again,
    :edit,
    :cv,
    :pipeline,
    :follow_up,
    :label,
    :add_task,
    :converse,
    :meet,
    :request_approval
  ]
  @keep_actions [:archive, :unarchive, :pin, :unpin]

  @view_words "You can see this, but only its owner or a team lead can change it."
  @assign_words "Only the owner or a team lead can hand this lead on."
  @keep_words "Only the lead's owner, or a team lead, can archive or pin it."
  @applied_words "You can say you applied while it is still To do."
  @team_words "That is for the team serving you to do."
  @note_words "Only the people working this lead can add a note."
  @note_change_words "Only its author or a team lead can change a note."
  @label_words "Only a team lead can change the team's labels."

  @doc "Every action a lead answers, for the matrix."
  def actions,
    do: [:read, :create, :assign, :share, :applied, :note | @change_actions ++ @keep_actions]

  @doc "The verbs a member at `view` is refused with the view-only words."
  def change_actions, do: @change_actions

  @doc "The view-only words (§4.2)."
  def view_words, do: @view_words

  @doc "The decision for `action` on `lead`."
  @spec decide(Scope.t(), atom(), map()) :: :ok | {:error, term()}
  def decide(%Scope{} = scope, action, lead) do
    cond do
      not same_organisation?(scope, lead) -> {:error, :not_found}
      Scope.customer?(scope) -> customer(scope, action, lead)
      not Scope.staff?(scope) -> {:error, :not_found}
      is_nil(Map.get(lead, :id)) -> unmade(scope, action, lead)
      true -> staff(scope, action, lead)
    end
  end

  @doc "Whether the caller sees `lead` at all."
  @spec visible?(Scope.t(), map()) :: boolean()
  def visible?(%Scope{} = scope, lead), do: decide(scope, :read, lead) == :ok

  @doc """
  What the caller sees of a team's leads: `:all` (the system admin, its
  leads, a member at `view` or `edit`), `{:own, user_id}` (a member at
  `hidden`), or `:none` (not in the team).
  """
  @spec board_reach(Scope.t(), binary()) :: :all | {:own, binary()} | :none
  def board_reach(%Scope{} = scope, team_id) do
    cond do
      Scope.admin?(scope) -> :all
      Scope.team_role(scope, team_id) == :lead -> :all
      Scope.team_role(scope, team_id) != :member -> :none
      peer_level(scope, team_id) == :hidden -> {:own, Scope.user_id(scope)}
      true -> :all
    end
  end

  @doc "The words for adding a note (AQ-04B §4)."
  def note_words, do: @note_words

  @doc "The words for changing a note (AQ-04B §4)."
  def note_change_words, do: @note_change_words

  @doc "The words for changing the team's labels (AQ-04B §4)."
  def label_words, do: @label_words

  @doc """
  A note on a lead (AQ-04B §4): `note` carries `author_user_id` and `lead`
  (the lead's subject). `:edit` and `:delete` are its author's (while they
  still see the lead) or a team lead's (the system admin's too); anyone who
  does not see the lead, and every customer, finds nothing.
  """
  @spec decide_note(Scope.t(), atom(), map()) :: :ok | {:error, term()}
  def decide_note(%Scope{} = scope, action, %{lead: lead} = note)
      when action in [:edit, :delete] do
    cond do
      Scope.customer?(scope) -> {:error, :not_found}
      decide(scope, :read, lead) != :ok -> {:error, :not_found}
      leads?(scope, lead) -> :ok
      note.author_user_id == Scope.user_id(scope) -> :ok
      true -> {:error, {:forbidden, @note_change_words}}
    end
  end

  def decide_note(_scope, _action, _note), do: {:error, :not_found}

  @doc """
  A team's labels (AQ-04B §4): `:read` for anyone in the team and the
  system admin; `:manage` (make, rename, remove) a team lead's or the
  system admin's, a member refused in words; anyone else finds nothing.
  """
  @spec decide_label(Scope.t(), atom(), map()) :: :ok | {:error, term()}
  def decide_label(%Scope{} = scope, action, %{team_id: team_id} = label) do
    cond do
      not same_organisation?(scope, label) -> {:error, :not_found}
      Scope.customer?(scope) -> {:error, :not_found}
      Scope.admin?(scope) -> :ok
      not in_team?(scope, team_id) -> {:error, :not_found}
      action == :read -> :ok
      action == :manage -> allow(Scope.team_role(scope, team_id) == :lead, @label_words)
      true -> {:error, :not_found}
    end
  end

  @doc """
  Settings › Retention for a team (AQ-04B §4, QP4b-7): the system admin,
  every team; a team lead, their teams; staff and everyone else, nothing.
  """
  @spec decide_retention(Scope.t(), map()) :: :ok | {:error, term()}
  def decide_retention(%Scope{} = scope, %{team_id: team_id}) do
    allow_found(Scope.admin?(scope) or Scope.team_role(scope, team_id) == :lead)
  end

  defp allow_found(true), do: :ok
  defp allow_found(false), do: {:error, :not_found}

  # ── A lead not made yet: its team and its customer decide ───────────────────

  defp unmade(scope, :create, %{team_id: team_id} = lead) do
    customer = Map.get(lead, :customer)

    cond do
      not (Scope.admin?(scope) or in_team?(scope, team_id)) ->
        {:error, :not_found}

      is_nil(customer) ->
        :ok

      team_id in (customer.team_ids || []) ->
        :ok

      true ->
        {:error, {:forbidden, "#{lead[:team_name]} doesn't serve #{customer.display_name}."}}
    end
  end

  defp unmade(_scope, _action, _lead), do: {:error, :not_found}

  # ── Staff ───────────────────────────────────────────────────────────────────

  defp staff(scope, action, lead) do
    if sees?(scope, lead), do: seen(scope, action, lead), else: {:error, :not_found}
  end

  defp seen(_scope, action, _lead) when action in [:read, :share], do: :ok

  defp seen(scope, action, lead) when action in @change_actions,
    do: allow(changer?(scope, lead), @view_words)

  defp seen(scope, :note, lead), do: allow(changer?(scope, lead), @note_words)

  defp seen(scope, :assign, lead),
    do: allow(owner?(scope, lead) or leads?(scope, lead), @assign_words)

  defp seen(scope, action, lead) when action in @keep_actions,
    do: allow(owner?(scope, lead) or leads?(scope, lead), @keep_words)

  defp seen(_scope, _action, _lead), do: {:error, :not_found}

  defp sees?(scope, lead) do
    leads?(scope, lead) or (in_team?(scope, lead.team_id) and own?(scope, lead)) or
      peer_level(scope, lead.team_id) in [:view, :edit]
  end

  defp changer?(scope, lead) do
    leads?(scope, lead) or (in_team?(scope, lead.team_id) and owner?(scope, lead)) or
      peer_level(scope, lead.team_id) == :edit
  end

  defp leads?(scope, lead),
    do: Scope.admin?(scope) or Scope.team_role(scope, lead.team_id) == :lead

  defp in_team?(scope, team_id), do: not is_nil(Scope.team_role(scope, team_id))

  defp owner?(scope, lead),
    do: not is_nil(lead.owner_user_id) and lead.owner_user_id == Scope.user_id(scope)

  defp own?(scope, lead) do
    me = Scope.user_id(scope)
    lead.owner_user_id == me or (not is_nil(me) and Map.get(lead, :applied_by_user_id) == me)
  end

  # The team's `peer_leads` for a member of it; `nil` for anyone else.
  defp peer_level(scope, team_id) do
    with :member <- Scope.team_role(scope, team_id),
         %{peer_leads: level} <- Scope.team_settings(scope, team_id) do
      level
    else
      _other -> nil
    end
  end

  # ── The customer ────────────────────────────────────────────────────────────

  defp customer(scope, action, lead) do
    cond do
      Map.get(lead, :customer_id) != Scope.customer_id(scope) ->
        {:error, :not_found}

      is_nil(Map.get(lead, :id)) ->
        {:error, :not_found}

      action == :read ->
        :ok

      action == :applied ->
        allow(lead.state == :todo and is_nil(lead.archived_at), @applied_words)

      true ->
        {:error, {:forbidden, @team_words}}
    end
  end

  defp same_organisation?(scope, %{organisation_id: org_id}) when is_binary(org_id),
    do: org_id == Scope.organisation_id(scope)

  defp same_organisation?(_scope, _lead), do: true

  defp allow(true, _words), do: :ok
  defp allow(false, words), do: {:error, {:forbidden, words}}
end
