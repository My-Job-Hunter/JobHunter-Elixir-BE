defmodule Core.Access.Conversations do
  @moduledoc """
  Who sees and does what to contacts, conversations, messages and meetings
  (AQ-06 §4), **pure**: the `{:contact, _}`, `{:conversation, _}`,
  `{:message, _}` and `{:meeting, _}` rows of `Core.Access`. A
  conversation or a meeting is decided on **its leads, by P4a's rules**
  (`Core.Access.Leads`, the team's `peer_leads`): one rulebook.

  | Subject | Carries |
  |---|---|
  | `{:contact, c}` | `organisation_id` (none yet for a new one) |
  | `{:conversation, c}` | `organisation_id`, `team_id`, `customer_id`, `customer_sees` (the team's `customer_sees_conversations`), `leads` (each lead's subject, `Core.Leads.subject/1`) |
  | `{:message, m}` | `author_user_id`, `captured_via`, `is_internal`, `conversation` (as above) |
  | `{:meeting, m}` | `organisation_id`, `lead` (its lead's subject) |

  - **Contacts:** every staff member reads, adds and edits them (PLAN
    §3.3); merging is a team lead's or the system admin's ("Only a team
    lead can merge contacts."). The customer finds none.
  - **A conversation on leads** is seen by whoever reads one of its leads;
    `:write` (log a message, upload an `.eml`, classify, link a contact) is
    whoever may change one of them (`:converse`, P4a's words at `view`).
  - **A triage item** (on no lead) is its team's: every member reads and
    writes it, the system admin too; another team finds nothing.
    `:triage` (link, ignore, *Create job and lead*, *Mark as recruiter*) is
    any member of the conversation's team who sees it.
  - **A message** typed by hand is edited or deleted by its author or a
    team lead ("Only its author or a team lead can change this
    message."); a captured or `.eml` one never ("Captured messages can't
    be edited.").
  - **A meeting** is read with its lead and changed by whoever may change
    the lead (`:meet`).
  - **The customer** reads a conversation on their own lead when the
    lead's team has `customer_sees_conversations` on, never a staff note
    (cut in the context), never triage; their own leads' meetings always.
    They change nothing ("That is for the team serving you to do.").
  """

  alias Core.Access.Leads
  alias Data.Scope

  @merge_words "Only a team lead can merge contacts."
  @author_words "Only its author or a team lead can change this message."
  @captured_words "Captured messages can't be edited."
  @team_words "That is for the team serving you to do."

  @meeting_writes [:schedule, :reschedule, :cancel, :done, :no_show, :edit, :confirm, :dismiss]

  @doc "Every action a conversation answers, for the matrix."
  def conversation_actions, do: [:read, :write, :triage]

  @doc "Every action a meeting answers, for the matrix."
  def meeting_actions, do: [:read | @meeting_writes]

  @doc "The words for editing a captured message."
  def captured_words, do: @captured_words

  @doc "The words for editing another's message."
  def author_words, do: @author_words

  # ── Contacts ────────────────────────────────────────────────────────────────

  @spec decide_contact(Scope.t(), atom(), map()) :: :ok | {:error, term()}
  def decide_contact(%Scope{} = scope, action, contact) do
    cond do
      not same_organisation?(scope, contact) -> {:error, :not_found}
      Scope.customer?(scope) or not Scope.staff?(scope) -> {:error, :not_found}
      action in [:read, :create, :edit] -> :ok
      action == :merge -> allow(lead_anywhere?(scope), @merge_words)
      true -> {:error, :not_found}
    end
  end

  # ── Conversations ───────────────────────────────────────────────────────────

  @spec decide_conversation(Scope.t(), atom(), map()) :: :ok | {:error, term()}
  def decide_conversation(%Scope{} = scope, action, conversation) do
    cond do
      not same_organisation?(scope, conversation) -> {:error, :not_found}
      Scope.customer?(scope) -> customer(scope, action, conversation)
      not Scope.staff?(scope) -> {:error, :not_found}
      not reads?(scope, conversation) -> {:error, :not_found}
      true -> staff(scope, action, conversation)
    end
  end

  defp staff(_scope, :read, _conversation), do: :ok

  defp staff(scope, :write, %{leads: []} = conversation),
    do: allow(in_team?(scope, conversation.team_id), Leads.view_words())

  defp staff(scope, :write, %{leads: leads}) do
    allow(Enum.any?(leads, &(Leads.decide(scope, :converse, &1) == :ok)), Leads.view_words())
  end

  defp staff(scope, :triage, conversation),
    do: allow(in_team?(scope, conversation.team_id), Leads.view_words())

  defp staff(_scope, _action, _conversation), do: {:error, :not_found}

  defp reads?(scope, %{leads: []} = conversation), do: in_team?(scope, conversation.team_id)

  defp reads?(scope, %{leads: leads}),
    do: Enum.any?(leads, &(Leads.decide(scope, :read, &1) == :ok))

  defp customer(scope, action, conversation) do
    own? =
      Map.get(conversation, :customer_sees, false) and
        Enum.any?(conversation.leads, &(&1.customer_id == Scope.customer_id(scope)))

    cond do
      not own? -> {:error, :not_found}
      action == :read -> :ok
      true -> {:error, {:forbidden, @team_words}}
    end
  end

  # ── Messages ────────────────────────────────────────────────────────────────

  @spec decide_message(Scope.t(), atom(), map()) :: :ok | {:error, term()}
  def decide_message(%Scope{} = scope, action, %{conversation: conversation} = message) do
    read = decide_conversation(scope, :read, conversation)

    cond do
      read != :ok -> read
      Scope.customer?(scope) and (action != :read or message.is_internal) -> {:error, :not_found}
      action == :read -> :ok
      action == :classify -> decide_conversation(scope, :write, conversation)
      action in [:edit, :delete] -> change(scope, message, conversation)
      true -> {:error, :not_found}
    end
  end

  defp change(scope, message, conversation) do
    cond do
      message.captured_via != :manual -> {:error, {:forbidden, @captured_words}}
      Scope.admin?(scope) -> :ok
      Scope.team_role(scope, conversation.team_id) == :lead -> :ok
      not is_nil(message.author_user_id) and message.author_user_id == Scope.user_id(scope) -> :ok
      true -> {:error, {:forbidden, @author_words}}
    end
  end

  # ── Meetings ────────────────────────────────────────────────────────────────

  @spec decide_meeting(Scope.t(), atom(), map()) :: :ok | {:error, term()}
  def decide_meeting(%Scope{} = scope, :read, %{lead: lead}), do: Leads.decide(scope, :read, lead)

  def decide_meeting(%Scope{} = scope, action, %{lead: lead}) when action in @meeting_writes do
    case Leads.decide(scope, :read, lead) do
      :ok -> Leads.decide(scope, :meet, lead)
      refusal -> refusal
    end
  end

  def decide_meeting(_scope, _action, _meeting), do: {:error, :not_found}

  # ── Helpers ─────────────────────────────────────────────────────────────────

  defp in_team?(scope, team_id),
    do: Scope.admin?(scope) or not is_nil(Scope.team_role(scope, team_id))

  defp lead_anywhere?(scope), do: Scope.admin?(scope) or Scope.any_team?(scope, :lead)

  defp same_organisation?(scope, %{organisation_id: org_id}) when is_binary(org_id),
    do: org_id == Scope.organisation_id(scope)

  defp same_organisation?(_scope, _subject), do: true

  defp allow(true, _words), do: :ok
  defp allow(false, words), do: {:error, {:forbidden, words}}
end
