defmodule ApiShared.FallbackControllerTest do
  @moduledoc """
  Every clause answers the house shape with its stable code.
  """

  use ExUnit.Case, async: true

  import Plug.Test

  alias ApiShared.FallbackController

  defp answer(reason) do
    conn = FallbackController.call(conn(:get, "/"), {:error, reason})
    {conn.status, Jason.decode!(conn.resp_body), conn}
  end

  test "the shape is always error: code, message, details" do
    for reason <- [
          :not_found,
          :unauthenticated,
          :forbidden,
          :conflict,
          :rate_limited,
          :no_such_reason
        ] do
      {_status, body, _conn} = answer(reason)

      assert %{"error" => %{"code" => code, "message" => message, "details" => details}} = body
      assert is_binary(code) and is_binary(message) and is_map(details)
      assert Map.keys(body) == ["error"]
    end
  end

  test "identity_mismatch: 409 naming the account's customer, as far as the caller may know it (AQ-05 §8)" do
    mismatch = %{
      channel: %{id: "c1", kind: :linkedin, customer: %{id: "n1", display_name: "Naveed"}},
      kind: :linkedin,
      acting: %{display_name: "Tanweer"}
    }

    assert {409, %{"error" => error}, _conn} = answer({:identity_mismatch, mismatch})
    assert error["code"] == "identity_mismatch"

    assert error["message"] ==
             "You're signed in as Naveed's LinkedIn, not Tanweer's. Switch the acting profile, then press again."

    assert error["details"] == %{
             "channel" => %{
               "id" => "c1",
               "customer" => %{"id" => "n1", "display_name" => "Naveed"}
             }
           }

    assert {409, %{"error" => unseen}, _conn} =
             answer({:identity_mismatch, %{mismatch | channel: false, kind: :upwork}})

    assert unseen["message"] =~ "another customer's Upwork, not Tanweer's"
    assert unseen["details"] == %{"channel" => nil}
  end

  test "job_exists: 409 naming the job the link already is (AQ-03 §7)" do
    assert {409, %{"error" => error}, _conn} =
             answer({:job_exists, %{id: "j1", title: "Backend Developer"}})

    assert error["code"] == "job_exists"
    assert error["message"] == "That link is already in the pool: Backend Developer."
    assert error["details"] == %{"job_id" => "j1", "title" => "Backend Developer"}
  end

  test "job_exists for a teammate's job the caller may not see: the same code, naming nobody (AQ-03B)" do
    assert {409, %{"error" => error}, _conn} = answer({:job_exists, :hidden})
    assert error["code"] == "job_exists"

    assert error["message"] ==
             "That link is already in this team's pool, added by another member."

    assert error["details"] == %{"job_id" => nil, "title" => nil}
  end

  test "job_moved: 409 with the job's status now (AQ-03 §7)" do
    assert {409, %{"error" => error}, _conn} = answer({:job_moved, %{status: :closed}})
    assert error["code"] == "job_moved"
    assert error["message"] == "This job changed while you were looking. It's now closed."
    assert error["details"] == %{"status" => "closed"}
  end

  test "task_moved: 409 with where the task is now (AQ-02 §7.5)" do
    task = %{state: :in_progress, stage: %{id: "s1", name: "Sourcing", user_id: "u"}}

    assert {409, %{"error" => error}, _conn} = answer({:task_moved, task})
    assert error["code"] == "task_moved"
    assert error["message"] == "This task moved while you were looking. It's now In progress."

    assert error["details"] == %{
             "state" => "in_progress",
             "stage" => %{"id" => "s1", "name" => "Sourcing"}
           }

    assert {409, %{"error" => %{"details" => %{"stage" => nil}}}, _conn} =
             answer({:task_moved, %{state: :done, stage: nil}})
  end

  test "each reason maps to its status and code" do
    assert {404, %{"error" => %{"code" => "not_found"}}, _conn} = answer(:not_found)
    assert {401, %{"error" => %{"code" => "unauthenticated"}}, _conn} = answer(:unauthenticated)
    assert {403, %{"error" => %{"code" => "forbidden"}}, _conn} = answer(:forbidden)
    assert {409, %{"error" => %{"code" => "conflict"}}, _conn} = answer(:conflict)
    assert {429, %{"error" => %{"code" => "rate_limited"}}, _conn} = answer(:rate_limited)
  end

  test "a guard's own words are the message" do
    assert {403,
            %{"error" => %{"code" => "forbidden", "message" => "Only a team lead can do that."}},
            _conn} =
             answer({:forbidden, "Only a team lead can do that."})
  end

  test "a missing parameter names the field" do
    assert {422,
            %{
              "error" => %{
                "code" => "validation_failed",
                "details" => %{"url" => ["is required"]}
              }
            }, _conn} =
             answer({:missing, [:url]})
  end

  test "a changeset's errors become details" do
    changeset =
      {%{}, %{title: :string}}
      |> Ecto.Changeset.cast(%{}, [:title])
      |> Ecto.Changeset.validate_required([:title])

    assert {422,
            %{
              "error" => %{
                "code" => "validation_failed",
                "details" => %{"title" => ["can't be blank"]}
              }
            }, _conn} = answer(changeset)
  end

  test "a throttle says when it lifts, in the header and the details" do
    {status, body, conn} = answer({:rate_limited, 90})

    assert status == 429
    assert body["error"]["details"] == %{"retry_after_seconds" => 90}
    assert Plug.Conn.get_resp_header(conn, "retry-after") == ["90"]
  end

  test "an unmapped reason is a 500 that says nothing about internals" do
    ExUnit.CaptureLog.capture_log(fn ->
      assert {500, %{"error" => %{"code" => "internal_error", "details" => details}}, _conn} =
               answer({:db_exploded, "secret detail"})

      assert details == %{}
    end)
  end

  test "the leads' four codes (AQ-04A §8.4): duplicate_application, lead_moved, outcome_required, override_reason_required" do
    existing = %{applied_at: nil, team: "another"}

    assert {409, %{"error" => dup}, _conn} =
             answer(
               {:duplicate_application,
                %{
                  existing: existing,
                  message:
                    "“Golang” already has a lead on this job in another team, saved 12 Oct."
                }}
             )

    assert dup["code"] == "duplicate_application"
    assert dup["details"] == %{"existing" => %{"applied_at" => nil, "team" => "another"}}

    assert {409, %{"error" => moved}, _conn} =
             answer(
               {:lead_moved,
                %{
                  state: :in_progress,
                  stage: %{key: "technical_1", name: "Technical interview 1"},
                  outcome: nil
                }}
             )

    assert moved["code"] == "lead_moved"

    assert moved["message"] ==
             "This lead moved while you were looking. It's now In progress · Technical interview 1."

    assert moved["details"] == %{
             "state" => "in_progress",
             "stage" => %{"key" => "technical_1", "name" => "Technical interview 1"}
           }

    assert {422, %{"error" => %{"code" => "outcome_required", "message" => "Say how it ended."}},
            _} = answer(:outcome_required)

    assert {422,
            %{
              "error" => %{
                "code" => "override_reason_required",
                "details" => %{"reason" => ["is required"]}
              }
            }, _} =
             answer(:override_reason_required)
  end

  test "approval_not_pending: 409 with the state and version it is at now (AQ-07 §11.4)" do
    {status, body, _conn} =
      answer({:approval_not_pending, %{state: :changes_requested, version: 2}})

    assert status == 409

    assert body == %{
             "error" => %{
               "code" => "approval_not_pending",
               "message" =>
                 "This approval changed while you were looking. It's now Changes requested.",
               "details" => %{"state" => "changes_requested", "version" => 2}
             }
           }

    assert FallbackController.describe({:approval_not_pending, %{state: :approved, version: 1}}).code ==
             "approval_not_pending"
  end

  test "not_reviewer: 403 in §4's words (AQ-07 §4)" do
    {status, body, _conn} = answer(:not_reviewer)
    assert status == 403
    assert body["error"]["code"] == "not_reviewer"
    assert body["error"]["message"] == "This isn't yours to decide."
    assert FallbackController.describe(:not_reviewer).code == "not_reviewer"
  end
end
