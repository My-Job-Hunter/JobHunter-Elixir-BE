defmodule Core.Leads.History do
  @moduledoc """
  The lead page's History (AQ-04B §8.1): `GET /leads/:id/history?kind&before`,
  the ledger newest first, a keyset page of `event`s. `kind` is a comma
  list of `lead_event_kinds` (the chips: *Moves*, *Notes*, *Tasks*,
  *Follow-ups*, *System* are the client's groupings of them); `before` is
  the id of the last event seen. Whoever on the staff reads the lead reads
  its History; the customer reads theirs in the portal's sheet (its
  customer-visible rows, without reasons), so here a customer finds nothing.
  """

  alias Core.Leads
  alias Core.Leads.Sheet
  alias Data.Leads, as: Store
  alias Data.Scope
  alias Data.Vocabulary

  @page 50

  @doc "A page: `{items: [event], next_cursor}` (`next_cursor` the id to send as `before`, or nil)."
  @spec page(Scope.t(), term(), map()) :: {:ok, map()} | {:error, term()}
  def page(%Scope{} = scope, lead_id, params) do
    params = Leads.stringify(params)

    with :ok <- if(Scope.customer?(scope), do: {:error, :not_found}, else: :ok),
         {:ok, lead} <- Leads.fetch(scope, :read, lead_id),
         {:ok, kinds} <- kinds(params["kind"]),
         {:ok, before} <- before(lead, params["before"]) do
      events = Store.history(lead.id, kinds: kinds, before: before, limit: @page)

      {page, more} = Enum.split(events, @page)

      {:ok,
       %{
         items: Enum.map(page, &Sheet.event/1),
         next_cursor: if(more == [], do: nil, else: List.last(page).id)
       }}
    end
  end

  defp kinds(nil), do: {:ok, []}
  defp kinds(""), do: {:ok, []}

  defp kinds(value) do
    values = value |> to_string() |> String.split(",", trim: true) |> Enum.map(&String.trim/1)

    if Enum.all?(values, &(&1 in Vocabulary.lead_event_kinds())),
      do: {:ok, Enum.map(values, &String.to_atom/1)},
      else: Leads.invalid("kind", "has a value that is not one of the list")
  end

  defp before(_lead, nil), do: {:ok, nil}
  defp before(_lead, ""), do: {:ok, nil}

  defp before(lead, id) do
    case Store.event(lead.id, id) do
      nil -> Leads.invalid("before", "is not an event of this lead")
      event -> {:ok, event}
    end
  end
end
