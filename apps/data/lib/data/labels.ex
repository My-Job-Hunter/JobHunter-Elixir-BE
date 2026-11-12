defmodule Data.Labels do
  @moduledoc """
  A team's labels and the leads wearing them (AQ-04B §5.1, §9). Storage
  only: who makes a label or labels a lead is `Core.Access`'s, the ledger
  row `Core.Leads.Labels`'.
  """

  import Ecto.Query, warn: false

  alias Data.Labels.{Label, LeadLabel}
  alias Data.Repo

  @doc "A team's labels by name, each with how many leads wear it: `[{label, lead_count}]`."
  @spec list(binary()) :: [{Label.t(), non_neg_integer()}]
  def list(team_id) do
    from(l in Label,
      left_join: ll in LeadLabel,
      on: ll.label_id == l.id,
      where: l.team_id == ^team_id,
      group_by: l.id,
      order_by: [asc: l.name_normalized, asc: l.id],
      select: {l, count(ll.lead_id)}
    )
    |> Repo.all()
  end

  @doc "A label of the organisation; `nil` for a malformed or foreign id."
  @spec get(binary(), term()) :: Label.t() | nil
  def get(organisation_id, id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> Repo.get_by(Label, id: uuid, organisation_id: organisation_id)
      :error -> nil
    end
  end

  def get(_organisation_id, _id), do: nil

  @doc "The labels behind `ids` that belong to `team_id`."
  @spec in_team(binary(), [binary()]) :: [Label.t()]
  def in_team(_team_id, []), do: []

  def in_team(team_id, ids),
    do: Repo.all(from(l in Label, where: l.team_id == ^team_id and l.id in ^ids))

  @doc "How many leads wear a label."
  @spec lead_count(binary()) :: non_neg_integer()
  def lead_count(label_id),
    do: Repo.aggregate(from(ll in LeadLabel, where: ll.label_id == ^label_id), :count)

  @doc "Each lead's labels, by name: `%{lead_id => [label]}`."
  @spec for_leads([binary()]) :: %{binary() => [Label.t()]}
  def for_leads([]), do: %{}

  def for_leads(lead_ids) do
    from(ll in LeadLabel,
      join: l in assoc(ll, :label),
      where: ll.lead_id in ^lead_ids,
      order_by: [asc: l.name_normalized, asc: l.id],
      select: {ll.lead_id, l}
    )
    |> Repo.all()
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  @spec create(map()) :: {:ok, Label.t()} | {:error, Ecto.Changeset.t()}
  def create(attrs), do: %Label{} |> Label.changeset(attrs) |> Repo.insert()

  @spec rename(Label.t(), String.t()) :: {:ok, Label.t()} | {:error, Ecto.Changeset.t()}
  def rename(%Label{} = label, name), do: label |> Label.changeset(%{name: name}) |> Repo.update()

  @spec delete(Label.t()) :: {:ok, Label.t()} | {:error, Ecto.Changeset.t()}
  def delete(%Label{} = label), do: Repo.delete(label)

  @doc "Replaces a lead's labels with `label_ids`. Answers `{added, removed}` (ids)."
  @spec put_for_lead(binary(), [binary()]) :: {[binary()], [binary()]}
  def put_for_lead(lead_id, label_ids) do
    current =
      Repo.all(from(ll in LeadLabel, where: ll.lead_id == ^lead_id, select: ll.label_id))

    added = label_ids -- current
    removed = current -- label_ids

    if removed != [],
      do:
        Repo.delete_all(
          from(ll in LeadLabel, where: ll.lead_id == ^lead_id and ll.label_id in ^removed)
        )

    if added != [],
      do:
        Repo.insert_all(LeadLabel, Enum.map(added, &%{lead_id: lead_id, label_id: &1}),
          on_conflict: :nothing
        )

    {added, removed}
  end
end
