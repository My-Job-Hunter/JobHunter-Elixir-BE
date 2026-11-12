defmodule ApiTeam.ShareLinkJSON do
  @moduledoc """
  Share links' shapes (AQ-03B §5.1): the link (never its token), the link
  just made (with `path`, the one time the token is shown), and the shared
  item at its level. A `details` item is the console's sheet —
  `ApiShared.TasksJSON.sheet/1` or `ApiShared.JobsJSON.sheet/1` — without
  `can`, the suggestions or the reader's own state (`mine`, `me_on`); a lead's
  (AQ-04A §8.3) is `ApiShared.LeadsJSON.sheet/1` without `can`, its
  `history` every ledger row.
  """

  alias ApiShared.JobsJSON
  alias ApiShared.LeadsJSON
  alias ApiShared.TasksJSON
  alias Core.Tasks.Person

  @person ~w(user_id name photo_url)a
  @task_own ~w(can can_move mine me_on)a
  @job_own ~w(can suggestions best_suggestion leads hidden_leads)a

  @doc "`{id, level, expires_at, revoked_at, created_by, inserted_at}`."
  def link(l) do
    %{
      id: l.id,
      level: l.level,
      expires_at: l.expires_at,
      revoked_at: l.revoked_at,
      created_by: person(Person.view(l.created_by_user)),
      inserted_at: l.inserted_at
    }
  end

  @doc "The link just made: `link/1` plus `path`."
  def made(%{link: link, path: path}), do: link |> link() |> Map.put(:path, path)

  @doc "`GET /shared/:token`: `{subject, level, team, shared_by, expires_at, item}`."
  def shared(s) do
    %{
      subject: s.subject,
      level: s.level,
      team: s.team,
      shared_by: person(s.shared_by),
      expires_at: s.expires_at,
      item: item(s.subject, s.level, s.item)
    }
  end

  defp item(:task, :summary, t) do
    t
    |> Map.take(~w(id title state stage priority due_at due_on customer assignees author
                   inserted_at)a)
    |> Map.update!(:assignees, &Enum.map(&1, fn p -> person(p) end))
    |> Map.update!(:author, &person/1)
  end

  defp item(:task, level, t) do
    t
    |> TasksJSON.sheet()
    |> Map.drop(@task_own)
    |> Map.update!(:people, &Enum.map(&1, fn p -> Map.delete(p, :me) end))
    |> Map.update!(:steps, &Enum.map(&1, fn s -> Map.delete(s, :mine) end))
    |> history(level, t, &TasksJSON.history/1)
  end

  defp item(:job, :summary, j) do
    j
    |> Map.take(~w(id title company source status workplace engagement money posted_on
                   first_seen_at created_by)a)
    |> Map.update!(:created_by, &person/1)
  end

  defp item(:job, level, j) do
    j
    |> JobsJSON.sheet()
    |> Map.drop(@job_own)
    |> history(level, j, fn trail ->
      Enum.map(trail, &%{action: &1.action, by: person(&1.by), at: &1.at})
    end)
  end

  defp item(:lead, :summary, l) do
    l
    |> Map.take(
      ~w(id title company profile customer state stage outcome owner applied_at last_activity_at)a
    )
    |> Map.update!(:owner, &person/1)
  end

  defp item(:lead, level, l) do
    l
    |> LeadsJSON.sheet()
    |> Map.delete(:can)
    |> history(level, l, fn events -> Enum.map(events, &LeadsJSON.event/1) end)
  end

  defp history(map, :details_history, source, render),
    do: Map.put(map, :history, render.(source.history))

  defp history(map, _details, _source, _render), do: map

  defp person(nil), do: nil
  defp person(p), do: Map.take(p, @person)
end
