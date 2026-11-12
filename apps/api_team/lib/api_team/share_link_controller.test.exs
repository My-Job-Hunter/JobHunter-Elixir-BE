defmodule ApiTeam.ShareLinkControllerTest do
  @moduledoc """
  Share links over HTTP (AQ-03B §5.1), in the exact shapes: the link (with
  `path` only when made), the list without tokens, revoke's 403 words, and
  `GET /shared/:token` at each level — the `item` keys each level lists, and
  404 for a customer, a dead link, or nonsense.
  """

  use ApiTeam.TeamCase, async: true

  @link ~w(created_by expires_at id inserted_at level revoked_at)
  @shared ~w(expires_at item level shared_by subject team)
  @task_summary ~w(assignees author customer due_at due_on id inserted_at priority stage state title)
  @job_summary ~w(company created_by engagement first_seen_at id money posted_on source status title
                  workplace)

  setup do
    c = board_cast_fixture()
    farah = member_fixture(c.frontend, :member, user_fixture(display_name: "Farah"))

    task =
      task_fixture(scope_for(c.fiza), team: c.backend, primary: c.fiza, description: "Go roles")

    job = job_fixture(scope_for(c.fiza), team: c.backend, description_md: "Go and PostgreSQL.")
    Map.merge(c, %{farah: farah, task: task, job: job})
  end

  defp keys(map), do: map |> Map.keys() |> Enum.sort()

  defp share(c, path, level) do
    conn = call(c.fiza, :post, path, %{level: level})
    assert conn.status == 201
    made = body(conn)
    assert keys(made) == Enum.sort(["path" | @link])
    "/s/" <> token = made["path"]
    {made, token}
  end

  test "made, listed without tokens, opened at summary, revoked with the words; dead is 404", c do
    {made, token} = share(c, "/v1/jobs/#{c.job.id}/share-links", "summary")

    assert %{"level" => "summary", "revoked_at" => nil, "created_by" => %{"name" => "Fiza"}} =
             made

    assert [listed] = body(call(c.muaz, :get, "/v1/jobs/#{c.job.id}/share-links"))
    assert keys(listed) == @link and listed["id"] == made["id"]
    assert call(c.farah, :get, "/v1/jobs/#{c.job.id}/share-links").status == 404

    shared = body(call(c.farah, :get, "/v1/shared/#{token}"))
    assert keys(shared) == @shared

    assert %{"subject" => "job", "level" => "summary", "team" => %{"name" => "Backend squad"}} =
             shared

    assert keys(shared["item"]) == Enum.sort(@job_summary)

    tanweer = Data.Accounts.get_user(c.tanweer.user_id)
    assert call(tanweer, :get, "/v1/shared/#{token}").status == 404
    assert call(c.farah, :get, "/v1/shared/nonsense").status == 404

    conn = call(c.muaz, :post, "/v1/share-links/#{made["id"]}/revoke")
    assert conn.status == 403

    assert body(conn)["error"]["message"] ==
             "Only whoever made this link, or a team lead, can turn it off."

    revoked = body(call(c.fiza, :post, "/v1/share-links/#{made["id"]}/revoke"))
    assert keys(revoked) == @link and revoked["revoked_at"]
    assert call(c.farah, :get, "/v1/shared/#{token}").status == 404
  end

  test "a task at each level: summary's fields; details the sheet without the reader's own state",
       c do
    {_made, summary} = share(c, "/v1/tasks/#{c.task.id}/share-links", "summary")
    item = body(call(c.farah, :get, "/v1/shared/#{summary}"))["item"]
    assert keys(item) == Enum.sort(@task_summary)

    {_made, details} = share(c, "/v1/tasks/#{c.task.id}/share-links", "details")
    item = body(call(c.farah, :get, "/v1/shared/#{details}"))["item"]
    assert item["description"] == "Go roles"
    for gone <- ~w(can can_move mine me_on history), do: refute(Map.has_key?(item, gone))
    assert Enum.all?(item["people"], &(not Map.has_key?(&1, "me")))

    {_made, history} = share(c, "/v1/tasks/#{c.task.id}/share-links", "details_history")
    item = body(call(c.farah, :get, "/v1/shared/#{history}"))["item"]
    assert is_list(item["history"])
  end

  test "a job at details and details_history: no can, no suggestions; the trail", c do
    {_made, details} = share(c, "/v1/jobs/#{c.job.id}/share-links", "details")
    item = body(call(c.farah, :get, "/v1/shared/#{details}"))["item"]
    assert item["description_md"] == "Go and PostgreSQL."
    for gone <- ~w(can suggestions best_suggestion history), do: refute(Map.has_key?(item, gone))

    call(c.fiza, :patch, "/v1/jobs/#{c.job.id}", %{title: "Senior Go"})
    {_made, history} = share(c, "/v1/jobs/#{c.job.id}/share-links", "details_history")
    item = body(call(c.farah, :get, "/v1/shared/#{history}"))["item"]
    assert [%{"action" => "updated", "by" => %{"name" => "Fiza"}, "at" => _}] = item["history"]
  end

  test "422 for a level or an expiry off the list; 404 for an item the maker cannot see", c do
    path = "/v1/jobs/#{c.job.id}/share-links"
    assert call(c.fiza, :post, path, %{level: "all"}).status == 422
    assert call(c.fiza, :post, path, %{level: "summary", expires_in_days: 2}).status == 422
    assert call(c.fiza, :post, path, %{}).status == 422
    assert call(c.farah, :post, path, %{level: "summary"}).status == 404

    conn = call(c.fiza, :post, path, %{level: "details", expires_in_days: 30})
    assert conn.status == 201 and body(conn)["expires_at"]
  end
end
