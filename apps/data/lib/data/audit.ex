defmodule Data.Audit do
  @moduledoc """
  The audit log's rows (`audit_events`, JH-01 §4.2). Storage only: what to
  record and who may read it are `Core.Audit`'s.
  """

  import Ecto.Query, warn: false

  alias Data.Audit.AuditEvent
  alias Data.Repo

  @spec insert(map()) :: {:ok, AuditEvent.t()} | {:error, Ecto.Changeset.t()}
  def insert(attrs), do: %AuditEvent{} |> AuditEvent.changeset(attrs) |> Repo.insert()

  @doc "Every row about one subject, oldest first. For tests and a subject's Activity tab."
  @spec list_for_subject(binary(), String.t(), binary()) :: [AuditEvent.t()]
  def list_for_subject(organisation_id, subject_kind, subject_id) do
    from(e in AuditEvent,
      where:
        e.organisation_id == ^organisation_id and e.subject_kind == ^subject_kind and
          e.subject_id == ^subject_id,
      order_by: [asc: e.occurred_at, asc: e.id]
    )
    |> Repo.all()
  end

  @doc """
  A page of the log, newest first, by keyset. `filters` may name
  `subject_kind`, `subject_id`, `actor_user_id`, `from`, `to`, `team_ids`
  (rows about those teams: the team itself, or a row whose before/after names
  the team) and `cursor` (`{occurred_at, id}` of the last row seen).
  """
  @spec list(binary(), map(), pos_integer()) :: [AuditEvent.t()]
  def list(organisation_id, filters, limit) do
    from(e in AuditEvent,
      where: e.organisation_id == ^organisation_id,
      order_by: [desc: e.occurred_at, desc: e.id],
      limit: ^limit,
      preload: [actor_user: :person]
    )
    |> filter(:subject_kind, filters[:subject_kind])
    |> filter(:subject_id, filters[:subject_id])
    |> filter(:actor_user_id, filters[:actor_user_id])
    |> from_to(filters[:from], filters[:to])
    |> teams(filters[:team_ids])
    |> cursor(filters[:cursor])
    |> Repo.all()
  end

  defp filter(query, _field, nil), do: query
  defp filter(query, field, value), do: where(query, [e], field(e, ^field) == ^value)

  defp from_to(query, nil, nil), do: query
  defp from_to(query, %DateTime{} = from, nil), do: where(query, [e], e.occurred_at >= ^from)
  defp from_to(query, nil, %DateTime{} = to), do: where(query, [e], e.occurred_at <= ^to)
  defp from_to(query, from, to), do: query |> from_to(from, nil) |> from_to(nil, to)

  defp teams(query, nil), do: query

  defp teams(query, team_ids) do
    texts = Enum.map(team_ids, &to_string/1)

    where(
      query,
      [e],
      (e.subject_kind == "teams" and e.subject_id in ^team_ids) or
        fragment("(? ->> 'team_id') = ANY(?)", e.after, ^texts) or
        fragment("(? ->> 'team_id') = ANY(?)", e.before, ^texts)
    )
  end

  defp cursor(query, nil), do: query

  defp cursor(query, {%DateTime{} = at, id}) do
    where(query, [e], e.occurred_at < ^at or (e.occurred_at == ^at and e.id < ^id))
  end
end
