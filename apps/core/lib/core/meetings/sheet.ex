defmodule Core.Meetings.Sheet do
  @moduledoc """
  What a meeting looks like (AQ-06 §11.6): the **meeting** shape, its
  attendees, the clash warning (§8.1, QP6-17) and the stage a meeting kind
  offers (QP6-18). **The customer's view is cut here**: no staff note, no
  outcome note, no clash, nothing they may do, staff by first name only
  when the lead's team shows names.
  """

  alias Core.Access
  alias Core.Contacts
  alias Core.Leads
  alias Core.Meetings.Words
  alias Core.Tasks.Person
  alias Data.Meetings, as: Store
  alias Data.Meetings.Meeting
  alias Data.Scope
  alias Data.Teams
  alias Data.Vocabulary

  @kind_stage %{
    screening: :screening,
    technical: :interview,
    assessment_review: :assessment,
    ai_interview: :ai_interview,
    final: :final
  }

  # ── The shape (§11.6) ───────────────────────────────────────────────────────

  @doc "**meeting**, as `scope` sees it."
  @spec view(Scope.t(), Meeting.t()) :: map()
  def view(%Scope{} = scope, %Meeting{} = m) do
    customer? = Scope.customer?(scope)
    lead = m.lead
    open? = m.status == :scheduled
    names? = customer? and Teams.get_settings(lead.job.team_id).customer_sees_staff_names

    %{
      id: m.id,
      lead: lead_ref(lead),
      title: m.title,
      meeting_kind: m.meeting_kind,
      platform: m.platform,
      join_url: m.join_url,
      address: m.address,
      starts_at: m.starts_at,
      ends_at: m.ends_at,
      time_zone: m.time_zone,
      status: m.status,
      outcome_note: if(customer?, do: nil, else: m.outcome_note),
      notes_md: if(customer?, do: nil, else: m.notes_md),
      attendees: Enum.map(m.attendees, &attendee(&1, lead.profile.customer, customer?, names?)),
      sequence: m.sequence,
      source: m.source,
      clash:
        if(open? and not customer?, do: clash_for(scope, lead, m.starts_at, m.ends_at, m.id)),
      can: can(scope, m, open?)
    }
  end

  defp lead_ref(lead) do
    job = lead.job
    customer = lead.profile.customer

    %{
      id: lead.id,
      title: job.title,
      company: job.company && %{id: job.company.id, name: job.company.name},
      customer: %{id: customer.id, display_name: customer.display_name},
      profile: %{id: lead.profile.id, title: lead.profile.title}
    }
  end

  defp can(scope, m, open?) do
    may = &Access.can?(scope, &1, {:meeting, Core.Meetings.subject(m)})

    %{
      reschedule: open? and may.(:reschedule),
      cancel: open? and may.(:cancel),
      done: open? and may.(:done),
      no_show: open? and may.(:no_show),
      edit: may.(:edit)
    }
  end

  defp attendee(%{user_id: id, user: user}, customer, customer?, names?) when is_binary(id) do
    person =
      if customer?, do: Person.for_customer(user, customer, names?), else: Person.view(user)

    %{kind: :user, person: person, contact: nil}
  end

  defp attendee(%{contact_id: id, contact: contact}, _customer, _customer?, _names?)
       when is_binary(id),
       do: %{kind: :contact, person: nil, contact: Contacts.ref(contact)}

  defp attendee(_customer_row, customer, _customer?, _names?) do
    %{
      kind: :customer,
      person: %{user_id: customer.user_id, name: customer.display_name, photo_url: nil},
      contact: nil
    }
  end

  @doc false
  def clash_for(scope, lead, starts, ends, except_id) do
    customer = lead.profile.customer

    case Store.overlapping(customer.id, lead.id, starts, ends, except_id) do
      [] ->
        nil

      [m | _rest] ->
        named? =
          m.lead.job.team_id == lead.job.team_id and
            Access.can?(scope, :read, {:lead, Leads.subject(m.lead)})

        company = m.lead.job.company && m.lead.job.company.name

        %{
          words:
            Words.clash(
              customer.display_name,
              if(named?, do: m.title),
              if(named?, do: company),
              {m.starts_at, m.ends_at},
              zone(scope)
            )
        }
    end
  end

  @doc "The next stage of a meeting kind's stage kind after the lead's stage, as `{key, name, words}`, or `nil`."
  @spec stage_offer(map(), term()) :: map() | nil
  def stage_offer(lead, kind) do
    with kind when is_binary(kind) <- kind && to_string(kind),
         true <- kind in Vocabulary.meeting_kinds(),
         wanted when not is_nil(wanted) <- @kind_stage[String.to_existing_atom(kind)],
         stages = lead.pipeline_version.stages,
         at = Enum.find_index(stages, &(&1.id == lead.stage_id)) || -1,
         %{} = stage <-
           stages |> Enum.drop(at + 1) |> Enum.find(&(engine_kind(&1) == wanted)) do
      %{key: stage.key, name: stage.name, words: "Move to #{stage.name}?"}
    else
      _none -> nil
    end
  end

  defp engine_kind(%{kind: :custom, anchor_kind: anchor}), do: anchor
  defp engine_kind(%{kind: kind}), do: kind

  # The reader's zone: their person's, else the organisation's.
  defp zone(scope) do
    case Scope.user_id(scope) && Data.Accounts.get_user(Scope.user_id(scope)) do
      %{person: %{timezone: zone}} when is_binary(zone) -> zone
      _other -> Core.Tasks.zone(scope)
    end
  end
end
