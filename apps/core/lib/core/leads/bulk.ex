defmodule Core.Leads.Bulk do
  @moduledoc """
  Bulk actions on the Tracker (AQ-04B §4, §8.1, QP4b-19): `POST /leads/bulk
  {action, lead_ids, from?, …the verb's fields…}`. **Each lead goes
  through its own verb and its own transaction**, so the rules, the ledger,
  the audit rows, the notices and the broadcasts are the single verb's; a
  refusal stops that lead alone. The answer lists what was done and what
  was refused, with the verb's own reason (`{done: [id], refused: [{id,
  reason}]}`; the API words the reasons as its error codes).

  | `action` | Fields | Each lead |
  |---|---|---|
  | `assign` | `owner_user_id` | `Core.Leads.Change.assign/4` |
  | `move` | `state`, `stage?`, `hold_reason?`, `hold_until_on?`, `outcome?`, `outcome_note?`, `close_job?` | `Core.Leads.Act` `move`, from where the lead stands (or as `seen`) |
  | `label` | `label_ids` | the labels **added** to the lead's own (never removed) |
  | `archive` · `unarchive` | — | `Core.Leads.Change.flag/4` |

  `from` (optional; `seen` is the same) is what the client saw of each lead,
  `[{id, state, stage}]`, one per lead: a lead that has moved since is refused with
  `lead_moved` ("…2 couldn't be: they moved meanwhile."), whatever the
  action. At most 200 leads at once.
  """

  alias Core.Leads
  alias Core.Leads.{Act, Change, Labels}
  alias Core.Tasks.Write
  alias Data.Labels, as: LabelStore
  alias Data.Scope

  @actions ~w(assign move label archive unarchive)
  @max 200
  @move_fields ~w(state stage hold_reason hold_until_on outcome outcome_note close_job)

  @doc "Runs `action` on each lead. Answers `{:ok, %{done, refused: [%{id, reason}]}}`."
  @spec run(Scope.t(), map(), DateTime.t()) :: {:ok, map()} | {:error, term()}
  def run(%Scope{} = scope, params, %DateTime{} = now) do
    params = Leads.stringify(params)

    with {:ok, action} <- action(params["action"]),
         {:ok, ids} <- ids(params["lead_ids"]),
         {:ok, seen} <- seen(params["from"] || params["seen"]),
         :ok <- fields(action, params) do
      results = Enum.map(ids, &{&1, one(scope, action, &1, Map.get(seen, &1), params, now)})

      {:ok,
       %{
         done: for({id, :ok} <- results, do: id),
         refused: for({id, {:error, reason}} <- results, do: %{id: id, reason: reason})
       }}
    end
  end

  defp one(scope, action, id, seen, params, now) do
    with {:ok, lead} <- Leads.fetch(scope, :read, id),
         :ok <- still(lead, seen) do
      action
      |> act(scope, lead, params, now)
      |> case do
        {:ok, _sheet} -> :ok
        {:error, _reason} = error -> error
      end
    end
  end

  # What the client saw, when it said; else where the lead stands now.
  defp still(_lead, nil), do: :ok
  defp still(lead, seen), do: Act.at(lead, seen)

  defp from(lead),
    do: %{"state" => to_string(lead.state), "stage" => lead.stage && lead.stage.key}

  defp act("assign", scope, lead, params, now),
    do: Change.assign(scope, lead.id, %{"owner_user_id" => params["owner_user_id"]}, now)

  defp act("move", scope, lead, params, now) do
    body = params |> Map.take(@move_fields) |> Map.put("from", from(lead))
    Act.run(scope, :move, lead.id, body, now)
  end

  defp act("label", scope, lead, params, now) do
    with {:ok, lead} <- Leads.fetch(scope, :label, lead.id),
         {:ok, adding} <- Labels.of_team(lead.job.team_id, params["label_ids"]) do
      current = Map.get(LabelStore.for_leads([lead.id]), lead.id, [])
      labels = Enum.uniq_by(current ++ adding, & &1.id)
      Write.commit(fn -> Labels.relabel(scope, lead, labels, now) end)
    end
  end

  defp act(flag, scope, lead, _params, now) when flag in ~w(archive unarchive),
    do: Change.flag(scope, String.to_existing_atom(flag), lead.id, now)

  # ── The body ────────────────────────────────────────────────────────────────

  defp action(nil), do: {:error, {:missing, [:action]}}
  defp action(a) when a in @actions, do: {:ok, a}
  defp action(_a), do: Leads.invalid("action", "is assign, move, label, archive or unarchive")

  defp ids(nil), do: {:error, {:missing, [:lead_ids]}}
  defp ids([]), do: Leads.invalid("lead_ids", "Nothing selected.")

  defp ids(ids) when is_list(ids) and length(ids) <= @max,
    do: {:ok, ids |> Enum.map(&to_string/1) |> Enum.uniq()}

  defp ids(ids) when is_list(ids), do: Leads.invalid("lead_ids", "is at most #{@max} leads")
  defp ids(_ids), do: Leads.invalid("lead_ids", "is a list of lead ids")

  defp seen(nil), do: {:ok, %{}}

  defp seen(list) when is_list(list) do
    if Enum.all?(list, &(is_map(&1) and Map.has_key?(Leads.stringify(&1), "id"))),
      do: {:ok, Map.new(list, &{to_string(Leads.stringify(&1)["id"]), Leads.stringify(&1)})},
      else: Leads.invalid("from", "is a list of {id, state, stage}")
  end

  defp seen(_seen), do: Leads.invalid("from", "is a list of {id, state, stage}")

  defp fields("assign", %{"owner_user_id" => id}) when is_binary(id) and id != "", do: :ok
  defp fields("assign", _params), do: {:error, {:missing, [:owner_user_id]}}
  defp fields("move", %{"state" => s}) when is_binary(s) and s != "", do: :ok
  defp fields("move", _params), do: {:error, {:missing, [:state]}}
  defp fields("label", %{"label_ids" => [_ | _]}), do: :ok
  defp fields("label", %{"label_ids" => _}), do: Leads.invalid("label_ids", "names no label")
  defp fields("label", _params), do: {:error, {:missing, [:label_ids]}}
  defp fields(_flag, _params), do: :ok
end
