defmodule Api.CustomerChannelTest do
  @moduledoc "`customer:<id>` (AQ-02 §7.4): the customer and staff who read them; only tasks the customer sees."

  use Api.ChannelCase, async: true

  alias Core.Auth.Guardian
  alias Core.Leads.Act, as: LeadAct
  alias Core.Tasks.{Comments, Portal}

  @now ~U[2026-11-10 09:00:00.000000Z]

  setup do: board_cast_fixture()

  defp socket_for(user) do
    {:ok, tokens} = Guardian.tokens_for(user)
    {:ok, socket} = connect(Api.UserSocket, %{"token" => tokens.access_token})
    socket
  end

  defp login(customer), do: Data.Accounts.get_user(customer.user_id)

  test "the customer joins their own; staff who read them do; nobody else", c do
    topic = "customer:" <> c.tanweer.id

    assert {:ok, _reply, _socket} =
             subscribe_and_join(socket_for(login(c.tanweer)), Api.CustomerChannel, topic)

    assert {:ok, _reply, _socket} =
             subscribe_and_join(socket_for(c.fiza), Api.CustomerChannel, topic)

    assert {:error, %{reason: "unauthorized"}} =
             subscribe_and_join(socket_for(login(c.naveed)), Api.CustomerChannel, topic)

    assert {:error, %{reason: "unauthorized"}} =
             subscribe_and_join(
               socket_for(c.bilal),
               Api.CustomerChannel,
               "customer:" <> c.imran.id
             )
  end

  test "hears only tasks the customer sees, and never of a staff-only comment", c do
    {:ok, _reply, _socket} =
      subscribe_and_join(
        socket_for(login(c.tanweer)),
        Api.CustomerChannel,
        "customer:" <> c.tanweer.id
      )

    hira = scope_for(c.hira)

    {:ok, sheet} =
      Core.Tasks.create(
        hira,
        %{"title" => "Staff only", "team_id" => c.backend.id, "customer_id" => c.tanweer.id},
        @now
      )

    id = sheet.id
    refute_push "task_created", _payload

    {:ok, _sheet} = Core.Tasks.update(hira, id, %{"customer_access" => "shared"}, @now)
    assert_push "task_updated", %{task: ^id}

    {:ok, _thread} =
      Comments.create(
        hira,
        id,
        %{"body" => "Team only", "is_staff_only" => true},
        @now
      )

    refute_push "task_updated", _payload

    {:ok, _thread} =
      Comments.create(
        hira,
        id,
        %{"body" => "Hello Tanweer", "is_staff_only" => false},
        @now
      )

    assert_push "task_updated", %{task: ^id}

    {:ok, own} =
      Portal.create(customer_scope_for(c.tanweer), %{"title" => "Apply"}, @now)

    own_id = own.id
    assert_push "task_created", %{task: ^own_id}
  end

  test "the customer hears their own leads from every team (AQ-04A §10.2)", c do
    {:ok, _reply, _socket} =
      subscribe_and_join(
        socket_for(login(c.tanweer)),
        Api.CustomerChannel,
        "customer:" <> c.tanweer.id
      )

    fiza = scope_for(c.fiza)
    job = job_fixture(fiza, team: c.backend)

    {:ok, sheet} =
      Core.Leads.create(
        fiza,
        %{"job_id" => job.id, "profile_id" => c.golang.id, "as" => "apply"},
        @now
      )

    id = sheet.id
    assert_push "lead_created", %{lead: ^id}

    {:ok, _} =
      LeadAct.run(
        fiza,
        :move,
        id,
        %{
          "from" => %{"state" => "in_progress", "stage" => "applied"},
          "state" => "in_progress",
          "stage" => "technical_1"
        },
        @now
      )

    assert_push "lead_moved", %{lead: ^id}
  end
end
