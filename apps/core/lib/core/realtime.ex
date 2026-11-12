defmodule Core.Realtime do
  @moduledoc """
  The socket's topics (AQ-02 §7.4, §7.6; PLAN §15.6): **who may join** each,
  and **which events a change sends**. The channels in `api` ask the first;
  the contexts hand the second to `Core.Broadcast` after commit.

  | Topic | Who may join | Events (closed, ids only) |
  |---|---|---|
  | `user:<id>` | that user | `notification_created {id}`, `notifications_read {}`, `task_assigned {task}` |
  | `team:<id>` | the team's open members; the system admin | `task_created`, `task_updated`, `task_deleted` `{task}`; `team_settings_updated` `{team}`; `lead_created`, `lead_moved`, `lead_updated` `{lead}` for its jobs' leads (AQ-04A §10.2) |
  | `customer:<id>` | the customer's own login; staff who may read the customer | the same three, only for tasks the customer sees; `team_settings_updated` `{team}` for a team that serves them; the three lead events for every lead of theirs, from every team |
  | `lead:<id>` | whoever reads the lead (its team by `peer_leads`, the system admin), and its customer | `event_added {lead}` (every change that may write a ledger row; the lead events above send it too), `notes_changed {lead}` (AQ-04B §8.3); AQ-06 §11.6: `message_added {lead, conversation}`, `meeting_changed {lead, meeting}` |

  AQ-06 §11.6 adds `triage_changed {team}` on `team:<id>` (a conversation
  came into the team's triage or left it) and `meeting_changed {lead,
  meeting}` on `customer:<id>` too.

  AQ-07 §11.4 adds `approval_changed {approval, lead}` (`lead` `null` for a
  profile's) on `team:<id>` and, when the customer holds a slot of a
  submitted one, `customer:<id>`; a change that writes the lead's ledger
  sends `event_added` on `lead:<id>`. The nav's count follows it.

  `team_settings_updated` makes an open board re-read: a member's view of
  their peers' tasks, and the names a customer reads, follow a team's
  settings (AQ-02 §6.1, §6.4).

  A refused join gives no reason, whether the row exists or not.
  """

  alias Core.Access
  alias Core.Access.Grants
  alias Core.Access.Tasks, as: TaskAccess
  alias Core.Broadcast
  alias Data.Accounts
  alias Data.Customers
  alias Data.Scope
  alias Data.Teams

  @user_events ~w(notification_created notifications_read task_assigned)
  @board_events ~w(task_created task_updated task_deleted)
  @settings_event "team_settings_updated"
  @lead_events ~w(lead_created lead_moved lead_updated)
  @ledger_events ~w(event_added notes_changed)

  @doc "Whether `user_id` may join `topic`."
  @spec may_join?(binary(), String.t()) :: boolean()
  def may_join?(user_id, "user:" <> id), do: is_binary(user_id) and user_id == id

  def may_join?(user_id, "team:" <> id) do
    with %Scope{organisation: %{id: org_id}} = scope <- scope(user_id),
         %{archived_at: nil} <- Teams.get(org_id, id) do
      Scope.admin?(scope) or not is_nil(Scope.team_role(scope, id))
    else
      _other -> false
    end
  end

  def may_join?(user_id, "customer:" <> id) do
    with %Scope{organisation: %{id: org_id}} = scope <- scope(user_id),
         %{} = customer <- Customers.get(org_id, id) do
      Access.can?(scope, :read, {:customer, customer})
    else
      _other -> false
    end
  end

  def may_join?(user_id, "lead:" <> id) do
    with %Scope{organisation: %{id: org_id}} = scope <- scope(user_id),
         %{} = lead <- Data.Leads.get(org_id, id) do
      Access.can?(scope, :read, {:lead, Core.Leads.subject(lead)})
    else
      _other -> false
    end
  end

  def may_join?(_user_id, _topic), do: false

  defp scope(user_id) do
    case Accounts.get_user(user_id) do
      nil -> nil
      user -> Grants.scope_for(user)
    end
  end

  @doc """
  The board events for a change to a task: `team:` for its team before and
  after, `customer:` when the customer saw it before or sees it after.
  `opts`: `customer: false` keeps it off the customer's topic (a staff-only
  comment).
  """
  @spec task_events(String.t(), map() | nil, map(), keyword()) :: [
          {String.t(), String.t(), map()}
        ]
  def task_events(event, before, task, opts \\ []) when event in @board_events do
    tasks = Enum.reject([before, task], &is_nil/1)
    payload = %{task: task.id}

    teams = tasks |> Enum.map(& &1.team_id) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    customers =
      if Keyword.get(opts, :customer, true),
        do: tasks |> Enum.filter(&TaskAccess.customer_sees?/1) |> Enum.map(& &1.customer_id),
        else: []

    Enum.map(teams, &{"team:" <> &1, event, payload}) ++
      Enum.map(Enum.uniq(customers), &{"customer:" <> &1, event, payload})
  end

  @doc """
  The events for a change to a lead (§10.2): `lead_created`, `lead_moved`
  (state, stage, outcome, hold, archive) or `lead_updated` (owner, CV,
  pipeline, pin, facts), `{lead}`, on `team:` of its job's team and
  `customer:` of its profile's customer.
  """
  @spec lead_events(String.t(), map()) :: [{String.t(), String.t(), map()}]
  def lead_events(event, lead) when event in @lead_events do
    payload = %{lead: lead.id}

    [
      {"team:" <> lead.job.team_id, event, payload},
      {"customer:" <> lead.profile.customer_id, event, payload},
      {"lead:" <> lead.id, "event_added", payload}
    ]
  end

  @doc """
  An event on the lead's own topic (AQ-04B §8.3): `event_added` (its ledger
  grew) or `notes_changed` (a note was added, edited or deleted), `{lead}`.
  """
  @spec lead_topic(String.t(), binary()) :: {String.t(), String.t(), map()}
  def lead_topic(event, lead_id) when event in @ledger_events,
    do: {"lead:" <> lead_id, event, %{lead: lead_id}}

  @doc "A message added, edited or deleted in a conversation of the lead (AQ-06 §11.6): `lead:`, ids only."
  @spec message_added(binary(), binary()) :: {String.t(), String.t(), map()}
  def message_added(lead_id, conversation_id),
    do: {"lead:" <> lead_id, "message_added", %{lead: lead_id, conversation: conversation_id}}

  @doc "A meeting of the lead scheduled or changed (AQ-06 §11.6): `lead:` and the customer's `customer:`."
  @spec meeting_changed(map(), binary()) :: [{String.t(), String.t(), map()}]
  def meeting_changed(lead, meeting_id) do
    payload = %{lead: lead.id, meeting: meeting_id}

    [
      {"lead:" <> lead.id, "meeting_changed", payload},
      {"customer:" <> lead.profile.customer_id, "meeting_changed", payload}
    ]
  end

  @doc """
  An approval changed (AQ-07 §11.4): `approval_changed {approval, lead}` on
  `team:` and — when the customer holds a slot of a submitted one —
  `customer:`; with `ledger: true` (the lead's ledger grew) `event_added`
  on `lead:` too.
  """
  @spec approval_changed(map(), keyword()) :: [{String.t(), String.t(), map()}]
  def approval_changed(approval, opts \\ []) do
    payload = %{approval: approval.id, lead: approval.lead_id}

    customer? =
      approval.state != :draft and Enum.any?(approval.reviewers, &(&1.slot == :customer))

    [{"team:" <> approval.team_id, "approval_changed", payload}] ++
      if(customer?,
        do: [{"customer:" <> approval.customer_id, "approval_changed", payload}],
        else: []
      ) ++
      if(Keyword.get(opts, :ledger, false) and approval.lead_id,
        do: [lead_topic("event_added", approval.lead_id)],
        else: []
      )
  end

  @doc "A team's triage changed (AQ-06 §11.6): `team:`, `{team}`."
  @spec triage_changed(binary()) :: {String.t(), String.t(), map()}
  def triage_changed(team_id), do: {"team:" <> team_id, "triage_changed", %{team: team_id}}

  @doc "A team's settings changed: its `team:` topic and the `customer:` topic of each customer it serves."
  @spec team_settings_events(binary(), [binary()]) :: [{String.t(), String.t(), map()}]
  def team_settings_events(team_id, customer_ids) do
    payload = %{team: team_id}

    [{"team:" <> team_id, @settings_event, payload}] ++
      Enum.map(Enum.uniq(customer_ids), &{"customer:" <> &1, @settings_event, payload})
  end

  @doc "An event for one person's `user:` topic."
  @spec to_user(binary(), String.t(), map()) :: {String.t(), String.t(), map()}
  def to_user(user_id, event, payload) when event in @user_events,
    do: {"user:" <> user_id, event, payload}

  @doc "Sends the events, once each. Called after commit."
  @spec send_all([{String.t(), String.t(), map()}]) :: :ok
  def send_all(events) do
    events
    |> Enum.uniq()
    |> Enum.each(fn {topic, event, payload} -> Broadcast.broadcast(topic, event, payload) end)
  end
end
