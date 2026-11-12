defmodule Core.Leads.Ledger do
  @moduledoc """
  A lead's ledger (AQ-04A §5.2, §7, QP4a-5): one `lead_events` row per verb
  that moves or reassigns a lead, written in the verb's transaction, never
  updated.

  - **Who:** `actor_kind` is `customer` from the portal, `extension` for
    staff through the extension (`via: :extension`, AQ-05 §11.4), `user`
    for staff otherwise, `system` with nobody in the scope; a person's id
    rides along. An extension row carries the queued write's `request_id`
    (§10.4) when the verb was given one.
  - **Who reads it** (§7): `saved`, `applied`, `stage_moved`, `state_moved`
    (into and out of On hold), `outcome_set` and `reopened` are the
    customer's too; `owner_changed`, `pipeline_changed`, `cv_set`,
    `archived` and `unarchived` are staff only. P4b (AQ-04B §10):
    `follow_up_logged` is the customer's; `note_added`, `labelled`,
    `follow_up_due` and `archive_warned` are staff only; `task_created` and
    `task_done` follow the task (the customer's when it is shown to them),
    passed as `visibility`. The customer never reads a
    note (`Core.Leads.Sheet` cuts it). AQ-06 §11.6: `conversation_linked`,
    `contact_linked`, `contact_unlinked` and `classified` are staff only;
    the meeting kinds are the customer's; `message_in` and `message_out`
    follow the team's `customer_sees_conversations`, passed as
    `visibility`.
  - **Activity** (§7, PLAN §6.6): every event made by a person — `user`,
    `customer` or `extension` (a press is a person's act, Q8) — moves the
    lead's `last_activity_at` and its job's, so P4b's sweep reads one
    column. Pin, unpin and edit are audit rows, not events: they move
    nothing.
  """

  alias Data.Jobs, as: JobStore
  alias Data.Leads, as: Store
  alias Data.Leads.{Event, Lead}
  alias Data.Scope

  @staff_only [
    :owner_changed,
    :pipeline_changed,
    :cv_set,
    :archived,
    :unarchived,
    :note_added,
    :labelled,
    :follow_up_due,
    :archive_warned,
    :conversation_linked,
    :contact_linked,
    :contact_unlinked,
    :classified
  ]

  @doc """
  Writes one event of `kind` on `lead` (`attrs`: `from_label`, `to_label`,
  `outcome`, `note`, `document_id`, `task_id`, `note_id`, `is_again`,
  `occurred_at`, `request_id`, and `visibility` where the kind does not decide it) and, for a
  person's, moves the activity. Answers the event; raises (rolling the verb
  back) on a row it cannot write.
  """
  @spec record(Scope.t(), Lead.t(), atom(), map(), DateTime.t()) :: Event.t()
  def record(%Scope{} = scope, %Lead{} = lead, kind, attrs, %DateTime{} = now) do
    actor_kind = actor_kind(scope)

    {:ok, event} =
      attrs
      |> Map.merge(%{
        organisation_id: lead.organisation_id,
        lead_id: lead.id,
        kind: kind,
        occurred_at: Map.get(attrs, :occurred_at) || now,
        recorded_at: now,
        actor_kind: actor_kind,
        actor_user_id: Scope.user_id(scope),
        visibility:
          Map.get(attrs, :visibility) || if(kind in @staff_only, do: :staff, else: :customer)
      })
      |> Store.add_event()

    if actor_kind in [:user, :customer, :extension], do: touch(lead, now)
    event
  end

  @doc "Who made a row, for the scope acting."
  @spec actor_kind(Scope.t()) :: :customer | :extension | :user | :system
  def actor_kind(%Scope{} = scope) do
    cond do
      Scope.customer?(scope) -> :customer
      Scope.user_id(scope) && scope.via == :extension -> :extension
      Scope.user_id(scope) -> :user
      true -> :system
    end
  end

  defp touch(lead, now) do
    :ok = Store.touch(lead, now)
    :ok = JobStore.touch(lead.job, now)
  end
end
