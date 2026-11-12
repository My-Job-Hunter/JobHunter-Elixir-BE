defmodule Notifire.EmailTest do
  use Notifire.NotifireCase, async: true

  alias Notifire.Email

  @now ~U[2026-11-09 10:00:00.000000Z]

  test "the invitation names who, what and the console link" do
    org = organisation_fixture(name: "Regbits BD")
    team = team_fixture(org, name: "Backend squad")
    inviter = admin_fixture(org)

    inv =
      invitation_fixture(org,
        team: team,
        role: :lead,
        email: "hira@example.com",
        invited_by_user_id: inviter.id
      )

    inv = Data.Invitations.get_for_system(inv.id)

    mail = Email.invitation(inv)
    assert mail.to == [{"Invited Person", "hira@example.com"}]
    assert mail.subject == "Test Person invited you to Regbits BD"
    assert mail.text_body =~ "as a team lead of Backend squad"
    assert mail.text_body =~ "http://localhost:5800/invite/#{inv.code}"
  end

  test "an admin invitation with no inviter is from the organisation" do
    org = organisation_fixture(name: "Regbits BD")

    inv =
      org
      |> invitation_fixture(invited_name: nil)
      |> then(&Data.Invitations.get_for_system(&1.id))

    mail = Email.invitation(inv)
    assert mail.subject == "Regbits BD invited you to Regbits BD"
    assert mail.text_body =~ "as an admin"
    assert [{_no_name, address}] = mail.to
    assert address == inv.email
  end

  test "the reset carries the token in a visible link and says how long it lasts" do
    user = user_fixture()
    {:ok, {token, row}} = Data.Accounts.create_token(user, :reset_password, @now)
    mail = Email.password_reset(row, token)
    assert mail.to == [{"Test Person", user.email}]
    assert mail.text_body =~ "reset-password?token=#{URI.encode(token)}"
    assert mail.text_body =~ "an hour"
  end

  test "the email change goes to the new address, never the old" do
    user = user_fixture()

    {:ok, {token, row}} =
      Data.Accounts.create_token(user, :change_email, @now, new_email: "new@example.com")

    mail = Email.email_change(row, token)
    assert mail.to == [{"Test Person", "new@example.com"}]
    assert mail.text_body =~ "confirm-email?token="
  end

  # AQ-08 §7.7, §11.4: the delivery tests read the whole form from the
  # mailbox; here, what only the builder shows.
  test "a notification: the subject on one line; a cancelled meeting's invite is a CANCEL" do
    user = user_fixture(display_name: "Hira Khan")
    recipient = Data.Notifications.recipient(user.id)

    notification = %{
      notification_kind_key: "meetings.changed",
      title: "Technical interview with Corvid Security\nwas cancelled",
      body: nil,
      link_path: "/leads/1"
    }

    mail =
      Email.for_notification(notification, recipient, "METHOD:CANCEL\r\nSTATUS:CANCELLED\r\n")

    assert mail.subject == "Technical interview with Corvid Security was cancelled"
    assert mail.to == [{"Hira Khan", user.email}]

    assert [%{content_type: "text/calendar; method=CANCEL", filename: "invite.ics"}] =
             mail.attachments

    assert mail.text_body =~ "http://localhost:5800/leads/1\n"

    assert Email.for_notification(notification, recipient).attachments == []
  end
end
