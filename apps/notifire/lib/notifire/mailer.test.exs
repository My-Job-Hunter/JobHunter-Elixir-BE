defmodule Notifire.MailerTest do
  @moduledoc """
  The mailer is wired to the test adapter, so nothing leaves the machine and a
  test can see what would have.
  """

  use ExUnit.Case, async: true

  import Swoosh.TestAssertions

  test "delivers into the test mailbox" do
    email =
      Swoosh.Email.new(
        to: "tanweer@example.com",
        from: {"Job Hunter", "hello@example.com"},
        subject: "Your interview is tomorrow",
        text_body: "Screening with the hiring manager, 10:00."
      )

    assert {:ok, _metadata} = Notifire.Mailer.deliver(email)
    assert_email_sent(subject: "Your interview is tomorrow", to: "tanweer@example.com")
  end
end
