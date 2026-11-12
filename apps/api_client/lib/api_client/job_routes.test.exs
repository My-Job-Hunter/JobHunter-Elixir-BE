defmodule ApiClient.JobRoutesTest do
  @moduledoc """
  AQ-03 §4.1, §10.2: the portal has no job route in P3 — the customer sees
  jobs through their leads, and leads arrive in P4a (QP3-12).
  """

  use ApiClient.ClientCase, async: true

  setup do: board_cast_fixture()

  test "GET /client/v1/jobs is 404 for the customer, and so is every job and company path", c do
    job = job_fixture(scope_for(c.fiza))

    for {method, path} <- [
          {:get, "/v1/jobs"},
          {:get, "/v1/jobs/#{job.id}"},
          {:post, "/v1/jobs/check"},
          {:get, "/v1/companies"}
        ] do
      conn = as_customer(c.tanweer, method, path)
      assert conn.status == 404, "#{method} #{path} answered #{conn.status}"
      assert code(conn) == "not_found"
    end
  end
end
