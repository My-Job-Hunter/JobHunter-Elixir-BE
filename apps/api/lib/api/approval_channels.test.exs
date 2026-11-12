defmodule Api.ApprovalChannelsTest do
  @moduledoc """
  AQ-07 §11.4 over real channels, after commit and ids only:
  `approval_changed {approval, lead}` on `team:` and — once submitted,
  with a customer slot — `customer:`; `event_added {lead}` on `lead:` when
  the ledger grew; a staff-only approval never reaches the customer.
  """

  use Api.ChannelCase, async: true

  alias Core.Approvals
  alias Core.Approvals.Act
  alias Core.Auth.Guardian

  @now ~U[2026-11-12 09:00:00.000000Z]

  setup do
    c = board_cast_fixture()
    lead = lead_fixture(scope_for(c.fiza), team: c.backend, profile: c.golang, as: :apply)
    Map.put(c, :lead, lead)
  end

  defp socket_for(user) do
    {:ok, tokens} = Guardian.tokens_for(user)
    {:ok, socket} = connect(Api.UserSocket, %{"token" => tokens.access_token})
    socket
  end

  test "team: and customer: hear approval_changed; lead: hears event_added", c do
    id = c.lead.id
    tanweer = Data.Accounts.get_user(c.tanweer.user_id)
    {:ok, _, _} = subscribe_and_join(socket_for(c.hira), Api.TeamChannel, "team:" <> c.backend.id)
    {:ok, _, _} = subscribe_and_join(socket_for(c.hira), Api.LeadChannel, "lead:" <> id)

    {:ok, _, _} =
      subscribe_and_join(socket_for(tanweer), Api.CustomerChannel, "customer:" <> c.tanweer.id)

    body = %{team_id: c.backend.id, lead_id: id, title: "x", body_md: ""}

    {:ok, staff} =
      Approvals.draft(
        scope_for(c.fiza),
        Map.merge(body, %{approval_kind: "asset", slots: [%{slot: "team_lead"}], submit: true}),
        @now
      )

    staff_id = staff.id
    assert_push "approval_changed", %{approval: ^staff_id, lead: ^id}
    assert_push "event_added", %{lead: ^id}
    refute_push "approval_changed", %{approval: ^staff_id}

    {:ok, a} =
      Approvals.draft(
        scope_for(c.fiza),
        Map.merge(body, %{approval_kind: "other", slots: [%{slot: "customer"}]}),
        @now
      )

    approval_id = a.id
    assert_push "approval_changed", %{approval: ^approval_id, lead: ^id}
    refute_push "approval_changed", %{approval: ^approval_id}

    {:ok, _} = Act.submit(scope_for(c.fiza), a.id, @now)
    assert_push "approval_changed", %{approval: ^approval_id, lead: ^id}
    assert_push "approval_changed", %{approval: ^approval_id, lead: ^id}
    assert_push "event_added", %{lead: ^id}
  end
end
