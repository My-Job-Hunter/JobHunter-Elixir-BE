defmodule Core.Audit do
  @moduledoc """
  The audit log (AQ-01 §4.2): every write records who did what, on what,
  before → after, **inside the same transaction as the write**. A rolled-back
  write leaves no row; a row with no write cannot exist.

      Repo.transaction(fn ->
        {:ok, team} = Teams.update(team, attrs)
        {:ok, _event} = Audit.record(scope, "updated", team, before: before, after: after)
        team
      end)

  `record/4` raises on a row it cannot write, which rolls the transaction
  back: an unauditable change is a change that did not happen.
  """

  alias Core.Clock
  alias Data.Audit
  alias Data.Audit.AuditEvent
  alias Data.Scope

  @doc """
  Writes one row. `subject` is a schema struct: its table is the
  `subject_kind`, its id the `subject_id`. Options: `:before` and `:after`
  (maps), `:organisation_id` when the scope has none yet (bootstrap), `:now`.
  """
  @spec record(Scope.t(), String.t(), struct(), keyword()) :: {:ok, AuditEvent.t()}
  def record(%Scope{} = scope, action, %{__struct__: schema} = subject, opts \\ [])
      when is_binary(action) do
    # The row's own key: `id` for most tables, `user_id`/`team_id` for the 1:1 settings.
    [key | _rest] = schema.__schema__(:primary_key)
    id = Map.fetch!(subject, key)

    attrs = %{
      organisation_id: Keyword.get(opts, :organisation_id) || Scope.organisation_id(scope),
      actor_user_id: Scope.user_id(scope),
      via: scope.via,
      subject_kind: schema.__schema__(:source),
      subject_id: id,
      action: action,
      before: plain(Keyword.get(opts, :before)),
      after: plain(Keyword.get(opts, :after)),
      request_id: scope.request_id,
      occurred_at: Keyword.get(opts, :now) || Clock.now()
    }

    case Audit.insert(attrs) do
      {:ok, event} -> {:ok, event}
      {:error, changeset} -> raise "audit row refused: #{inspect(changeset.errors)}"
    end
  end

  @doc """
  The fields of a struct worth writing into `before`/`after`: the listed
  ones, as a map with string keys and JSON-safe values.
  """
  @spec snapshot(struct() | map() | nil, [atom()]) :: map() | nil
  def snapshot(nil, _fields), do: nil

  def snapshot(struct, fields) do
    Map.new(fields, fn field -> {to_string(field), struct |> Map.get(field) |> plain_value()} end)
  end

  defp plain(nil), do: nil

  defp plain(map) when is_map(map),
    do: Map.new(map, fn {k, v} -> {to_string(k), plain_value(v)} end)

  defp plain_value(%DateTime{} = at), do: DateTime.to_iso8601(at)
  defp plain_value(%Date{} = on), do: Date.to_iso8601(on)
  defp plain_value(%Time{} = at), do: Time.to_iso8601(at)

  defp plain_value(value) when is_atom(value) and not is_boolean(value) and not is_nil(value),
    do: Atom.to_string(value)

  defp plain_value(value), do: value
end
