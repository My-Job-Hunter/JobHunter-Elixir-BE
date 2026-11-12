defmodule Core.Contacts.LeadLinks do
  @moduledoc """
  A lead's contacts (AQ-06 §5.1, §11.1): the **Recruiters** tab — your
  brief's "link multiple recruiters to that particular lead". Whoever may
  change the lead (`:converse`, P4a's words) links a contact in a role and
  unlinks it; each writes `contact_linked` / `contact_unlinked` (staff
  only) with the contact, audited, in one transaction. A merged contact is
  linked as its survivor.
  """

  alias Core.Access
  alias Core.Audit
  alias Core.Contacts
  alias Core.Leads
  alias Core.Leads.Ledger
  alias Core.Realtime
  alias Core.Tasks.Write
  alias Data.Contacts, as: Store
  alias Data.Contacts.LeadContact
  alias Data.Scope
  alias Data.Vocabulary

  @roles %{
    recruiter: "Recruiter",
    hiring_manager: "Hiring manager",
    interviewer: "Interviewer",
    client: "Client",
    referrer: "Referrer",
    other: "Contact"
  }

  @doc "A role as a person reads it."
  @spec role_words(atom() | String.t()) :: String.t()
  def role_words(role), do: Map.fetch!(@roles, String.to_existing_atom(to_string(role)))

  @doc "The lead sheet's `recruiters`: `[{contact, role}]`, in the order they were linked."
  @spec recruiters(Scope.t(), binary()) :: [map()]
  def recruiters(%Scope{} = scope, lead_id) do
    for lc <- Store.for_lead(lead_id),
        do: %{contact: Contacts.row(scope, lc.contact), role: lc.role}
  end

  @doc "`POST /leads/:id/contacts {contact_id, role}`: answers the lead's `recruiters`."
  @spec link(Scope.t(), term(), map(), DateTime.t()) :: {:ok, [map()]} | {:error, term()}
  def link(%Scope{} = scope, lead_id, params, %DateTime{} = now) do
    params = Leads.stringify(params)

    with {:ok, lead} <- Leads.fetch(scope, :converse, lead_id),
         {:ok, role} <- role(params["role"]),
         {:ok, contact} <- contact(scope, params["contact_id"]) do
      Write.commit(fn -> linked(scope, lead, contact, role, now) end)
      |> answer(scope, lead)
    end
  end

  @doc false
  # Inside a transaction: the link, its event and its audit row. A contact
  # on the lead already is kept as it is.
  def linked(scope, lead, contact, role, now) do
    case Store.lead_contact(lead.id, contact.id) do
      %LeadContact{} = held ->
        {:ok, held}

      nil ->
        attrs = %{
          lead_id: lead.id,
          contact_id: contact.id,
          role: role,
          linked_by_user_id: Scope.user_id(scope)
        }

        with {:ok, link} <- Store.link_lead(attrs) do
          _event =
            Ledger.record(
              scope,
              lead,
              :contact_linked,
              %{contact_id: contact.id, to_label: "#{contact.name} · #{role_words(role)}"},
              now
            )

          {:ok, _audit} = Audit.record(scope, "contact_linked", link, after: snap(link), now: now)
          {:ok, link, [Realtime.lead_events("lead_updated", lead)]}
        end
    end
  end

  @doc "`DELETE /leads/:id/contacts/:contact_id`: `contact_unlinked`, audited."
  @spec unlink(Scope.t(), term(), term(), DateTime.t()) :: :ok | {:error, term()}
  def unlink(%Scope{} = scope, lead_id, contact_id, %DateTime{} = now) do
    with {:ok, lead} <- Leads.fetch(scope, :converse, lead_id),
         %LeadContact{} = link <- Store.lead_contact(lead.id, contact_id) || {:error, :not_found},
         {:ok, _gone} <- Write.commit(fn -> unlinked(scope, lead, link, now) end),
         do: :ok
  end

  defp unlinked(scope, lead, link, now) do
    contact = Store.get(lead.organisation_id, link.contact_id)

    with {:ok, gone} <- Store.unlink_lead(link) do
      _event =
        Ledger.record(
          scope,
          lead,
          :contact_unlinked,
          %{contact_id: contact.id, from_label: "#{contact.name} · #{role_words(link.role)}"},
          now
        )

      {:ok, _audit} = Audit.record(scope, "contact_unlinked", gone, before: snap(gone), now: now)
      {:ok, gone, [Realtime.lead_events("lead_updated", lead)]}
    end
  end

  # A merged contact is linked as its survivor.
  defp contact(_scope, nil), do: {:error, {:missing, [:contact_id]}}

  defp contact(scope, id) do
    with :ok <- Access.why_not(scope, :read, {:contact, %{}}) do
      case Store.get(Scope.organisation_id(scope), id) do
        nil -> Leads.invalid("contact_id", "is not a contact")
        %{merged_into_contact_id: nil} = contact -> {:ok, contact}
        merged -> contact(scope, merged.merged_into_contact_id)
      end
    end
  end

  defp role(nil), do: {:error, {:missing, [:role]}}

  defp role(role) do
    if to_string(role) in Vocabulary.contact_roles(),
      do: {:ok, String.to_existing_atom(to_string(role))},
      else: Leads.invalid("role", "is not a role")
  end

  defp answer({:ok, _link}, scope, lead), do: {:ok, recruiters(scope, lead.id)}
  defp answer(error, _scope, _lead), do: error

  defp snap(link), do: Audit.snapshot(link, [:lead_id, :contact_id, :role])
end
