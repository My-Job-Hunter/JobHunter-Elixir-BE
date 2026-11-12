defmodule Core.Leads.Labels do
  @moduledoc """
  A team's labels (AQ-04B §4, §8.1, §9, QP4b-17): named, no colour, a
  filter on the board and the Tracker, a column, a bulk action.

  - `GET /labels?team_id`: anyone in the team (and the system admin).
  - `POST /labels {team_id, name}` · `PATCH /labels/:id {name}` ·
    `DELETE /labels/:id`: a team lead of the team or the system admin;
    "Only a team lead can change the team's labels." Audited.
  - `PUT /leads/:id/labels {label_ids}`: whoever may change the lead;
    replaces the set with labels **of the lead's team**, and writes
    `labelled` (staff) with the names before and after, only when the set
    changed.

  A label is `{id, name, lead_count}` (§8.4).
  """

  alias Core.Access
  alias Core.Audit
  alias Core.Jobs
  alias Core.Leads
  alias Core.Leads.Ledger
  alias Core.Realtime
  alias Core.Tasks.Write
  alias Data.Labels, as: Store
  alias Data.Labels.Label
  alias Data.Scope

  @doc "`GET /labels?team_id`: the team's labels by name."
  @spec list(Scope.t(), map()) :: {:ok, [map()]} | {:error, term()}
  def list(%Scope{} = scope, params) do
    params = Leads.stringify(params)

    with {:ok, team} <- team(scope, params),
         :ok <- Access.why_not(scope, :read, {:label, subject(team)}) do
      {:ok, Enum.map(Store.list(team.id), fn {label, n} -> view(label, n) end)}
    end
  end

  @doc "`POST /labels {team_id, name}`."
  @spec create(Scope.t(), map(), DateTime.t()) :: {:ok, map()} | {:error, term()}
  def create(%Scope{} = scope, params, %DateTime{} = now) do
    params = Leads.stringify(params)

    with {:ok, team} <- team(scope, params),
         :ok <- Access.why_not(scope, :manage, {:label, subject(team)}),
         {:ok, name} <- name(params) do
      attrs = %{organisation_id: team.organisation_id, team_id: team.id, name: name}

      Write.commit(fn -> made(scope, attrs, now) end)
      |> answer()
    end
  end

  @doc "`PATCH /labels/:id {name}`."
  @spec rename(Scope.t(), term(), map(), DateTime.t()) :: {:ok, map()} | {:error, term()}
  def rename(%Scope{} = scope, id, params, %DateTime{} = now) do
    params = Leads.stringify(params)

    with {:ok, label} <- fetch(scope, :manage, id),
         {:ok, name} <- name(params) do
      Write.commit(fn -> renamed(scope, label, name, now) end)
      |> answer()
    end
  end

  @doc "`DELETE /labels/:id`: the label leaves every lead wearing it."
  @spec delete(Scope.t(), term(), DateTime.t()) :: :ok | {:error, term()}
  def delete(%Scope{} = scope, id, %DateTime{} = now) do
    with {:ok, label} <- fetch(scope, :manage, id),
         {:ok, _label} <- Write.commit(fn -> deleted(scope, label, now) end),
         do: :ok
  end

  defp made(scope, attrs, now) do
    with {:ok, label} <- Store.create(attrs) do
      {:ok, _audit} = Audit.record(scope, "created", label, after: snapshot(label), now: now)
      {:ok, label}
    end
  end

  defp renamed(scope, label, name, now) do
    with {:ok, renamed} <- Store.rename(label, name) do
      {:ok, _audit} =
        Audit.record(scope, "renamed", renamed,
          before: snapshot(label),
          after: snapshot(renamed),
          now: now
        )

      {:ok, renamed}
    end
  end

  defp deleted(scope, label, now) do
    with {:ok, deleted} <- Store.delete(label) do
      {:ok, _audit} = Audit.record(scope, "deleted", deleted, before: snapshot(label), now: now)
      {:ok, deleted}
    end
  end

  @doc "`PUT /leads/:id/labels {label_ids}`: replaces the lead's labels. Answers the sheet."
  @spec put_on_lead(Scope.t(), term(), map(), DateTime.t()) :: {:ok, map()} | {:error, term()}
  def put_on_lead(%Scope{} = scope, id, params, %DateTime{} = now) do
    with {:ok, lead} <- Leads.fetch(scope, :label, id),
         {:ok, labels} <- of_team(lead.job.team_id, Leads.stringify(params)["label_ids"]) do
      Leads.answer(scope, Write.commit(fn -> relabel(scope, lead, labels, now) end), now)
    end
  end

  @doc false
  # The write `put_on_lead/4` and the bulk *Label…* share.
  def relabel(scope, lead, labels, now) do
    before = Map.get(Store.for_leads([lead.id]), lead.id, [])
    {added, removed} = Store.put_for_lead(lead.id, Enum.map(labels, & &1.id))

    if added == [] and removed == [] do
      {:ok, lead}
    else
      _event =
        Ledger.record(
          scope,
          lead,
          :labelled,
          %{from_label: names(before), to_label: names(labels)},
          now
        )

      {:ok, lead, [Realtime.lead_events("lead_updated", lead)]}
    end
  end

  @doc "The labels behind `ids`, each of `team_id`; anything else is a field error."
  @spec of_team(binary(), term()) :: {:ok, [Label.t()]} | {:error, term()}
  def of_team(_team_id, nil), do: {:error, {:missing, [:label_ids]}}

  def of_team(team_id, ids) when is_list(ids) do
    ids = ids |> Enum.map(&to_string/1) |> Enum.uniq()

    with {:ok, uuids} <- uuids(ids) do
      labels = Store.in_team(team_id, uuids)

      if length(labels) == length(uuids),
        do: {:ok, Enum.sort_by(labels, & &1.name_normalized)},
        else: Leads.invalid("label_ids", "has a label that is not this team's")
    end
  end

  def of_team(_team_id, _ids), do: Leads.invalid("label_ids", "is a list of label ids")

  defp uuids(ids) do
    Enum.reduce_while(ids, {:ok, []}, fn id, {:ok, acc} ->
      case Ecto.UUID.cast(id) do
        {:ok, uuid} -> {:cont, {:ok, acc ++ [uuid]}}
        :error -> {:halt, Leads.invalid("label_ids", "has a value that is not an id")}
      end
    end)
  end

  @doc "A label (§8.4): `{id, name, lead_count}`."
  @spec view(Label.t(), non_neg_integer()) :: map()
  def view(%Label{} = label, count), do: %{id: label.id, name: label.name, lead_count: count}

  # ── Helpers ─────────────────────────────────────────────────────────────────

  defp team(scope, params), do: Jobs.team(scope, params)

  defp subject(%Label{} = label),
    do: %{organisation_id: label.organisation_id, team_id: label.team_id}

  defp subject(team), do: %{organisation_id: team.organisation_id, team_id: team.id}

  defp fetch(scope, action, id) do
    with %Label{} = label <- Store.get(Scope.organisation_id(scope), id) || {:error, :not_found},
         :ok <- Access.why_not(scope, action, {:label, subject(label)}),
         do: {:ok, label}
  end

  defp name(params) do
    case Leads.blank(params["name"]) do
      nil -> {:error, {:missing, [:name]}}
      name -> {:ok, name}
    end
  end

  defp answer({:ok, label}), do: {:ok, view(label, Store.lead_count(label.id))}
  defp answer(error), do: error

  defp names([]), do: nil
  defp names(labels), do: Enum.map_join(labels, ", ", & &1.name)

  defp snapshot(label), do: Audit.snapshot(label, [:team_id, :name])
end
