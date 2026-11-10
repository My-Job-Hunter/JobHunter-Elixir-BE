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
end
