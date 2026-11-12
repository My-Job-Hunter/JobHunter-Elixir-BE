defmodule Data.Seeds.Notifications do
  @moduledoc """
  The notification groups and kinds (AQ-02 §8, §11): reference data, loaded
  in **every environment, test included**, idempotent by key. P2 brings the
  `tasks` group and its eight kinds; P4a the `leads` group and its four
  (AQ-04A §10.1); P4b three more (`leads.follow_up_due`,
  `leads.archive_warned`, `leads.archived`, AQ-04B §10); P6 the
  `conversations` and `meetings` groups and their five (AQ-06 §11.6, §14);
  P7 the `approvals` group and its six (AQ-07 §10, §14). A later phase adds
  its group here as rows, not as a migration.

  **P8 (AQ-08 §6, §11.4, §14)** corrects every kind's `default_channels` to
  PLAN §11's matrix, adds `leads.customer_milestone` and
  `meetings.day_before`, and the `account` group (`can_disable: false`, last)
  with `account.digest` and `account.push_test`. `meetings.reminder` and the
  two account kinds pass quiet hours. **Kinds are reference data owned by
  code**, so a load updates a kind or group that exists in place
  (`Data.Notifications.upsert_kind/1`): a changed default reaches a database
  seeded before the change. People's switches are their own rows, untouched.

  Each kind's **label** is code too (`label/1`): the name delivery health
  shows ("Approval requested"), since the table has no column for it.
  """

  alias Data.Notifications

  @groups [
    %{key: "tasks", label: "Tasks", position: 0, can_disable: true},
    %{key: "leads", label: "Leads", position: 1, can_disable: true},
    %{key: "conversations", label: "Conversations", position: 2, can_disable: true},
    %{key: "meetings", label: "Meetings", position: 3, can_disable: true},
    %{key: "approvals", label: "Approvals", position: 4, can_disable: true},
    %{key: "account", label: "Account", position: 5, can_disable: false}
  ]

  # `{key, default_channels, label, can_ignore_quiet_hours}`, AQ-08 §6 row by row.
  @kinds [
    {"tasks.assigned", ~w(inapp push), "Task assigned", false},
    {"tasks.customer_created", ~w(inapp push), "Customer added a task", false},
    {"tasks.commented", ~w(inapp push), "Task comment", false},
    {"tasks.mentioned", ~w(inapp push), "Mentioned on a task", false},
    {"tasks.completed", ~w(inapp), "Task done", false},
    {"tasks.due_soon", ~w(inapp digest), "Task due soon", false},
    {"tasks.overdue", ~w(inapp digest), "Task overdue", false},
    {"tasks.nudged", ~w(inapp push), "Nudged on a step", false},
    {"leads.assigned", ~w(inapp push), "Lead handed to you", false},
    {"leads.moved", ~w(inapp), "Lead moved", false},
    {"leads.applied_again", ~w(inapp), "Applied again", false},
    {"leads.customer_update", ~w(inapp), "Application update", false},
    {"leads.customer_milestone", ~w(inapp push email), "Your search moved forward", false},
    {"leads.follow_up_due", ~w(inapp digest), "Follow-up due", false},
    {"leads.archive_warned", ~w(inapp digest), "Archive warning", false},
    {"leads.archived", ~w(inapp digest), "Lead archived", false},
    {"conversations.reply_received", ~w(inapp push extension), "Reply received", false},
    {"conversations.triage_new", ~w(inapp digest), "New in Triage", false},
    {"meetings.scheduled", ~w(inapp push email), "Meeting scheduled", false},
    {"meetings.changed", ~w(inapp push email), "Meeting changed", false},
    {"meetings.day_before", ~w(inapp push email), "Meeting tomorrow", false},
    {"meetings.reminder", ~w(inapp push), "Meeting reminder", true},
    {"approvals.requested", ~w(inapp push email), "Approval requested", false},
    {"approvals.decided", ~w(inapp push email), "Approval decided", false},
    {"approvals.commented", ~w(inapp push), "Approval comment", false},
    {"approvals.due_soon", ~w(inapp push email), "Approval due soon", false},
    {"approvals.overdue", ~w(inapp push email), "Approval overdue", false},
    {"approvals.expired", ~w(inapp push email), "Approval expired", false},
    {"account.digest", ~w(inapp email), "Daily digest", true},
    {"account.push_test", ~w(inapp push), "Push test", true}
  ]

  @labels Map.new(@kinds, fn {key, _channels, label, _passes} -> {key, label} end)

  @doc "The kinds as `{key, default_channels}`, in their phases' order."
  def kinds, do: for({key, channels, _label, _passes} <- @kinds, do: {key, channels})

  @doc "The kinds that pass quiet hours (AQ-08 §7.3, QP8-8)."
  def passing_quiet_hours, do: for({key, _c, _l, true} <- @kinds, do: key)

  @doc """
  A kind's label, as delivery health names it; the key itself for a kind
  this list does not know.

      iex> Data.Seeds.Notifications.label("approvals.requested")
      "Approval requested"
  """
  @spec label(String.t()) :: String.t()
  def label(key), do: Map.get(@labels, key, key)

  @doc "Loads the groups, then the kinds. Answers `%{inserted, updated, kept}`."
  @spec load(keyword()) :: %{
          inserted: non_neg_integer(),
          updated: non_neg_integer(),
          kept: non_neg_integer()
        }
  def load(_opts \\ []) do
    groups = Enum.map(@groups, &Notifications.upsert_group/1)

    kinds =
      Enum.map(@kinds, fn {key, channels, _label, passes?} ->
        Notifications.upsert_kind(%{
          key: key,
          notification_group_key: key |> String.split(".") |> hd(),
          default_channels: channels,
          can_ignore_quiet_hours: passes?
        })
      end)

    Enum.reduce(
      groups ++ kinds,
      %{inserted: 0, updated: 0, kept: 0},
      &Map.update!(&2, &1, fn n -> n + 1 end)
    )
  end
end
