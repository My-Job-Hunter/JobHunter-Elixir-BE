defmodule Core.Inbound.GmailTest do
  @moduledoc "Gmail's forwarding confirmation recognised (AQ-09 §8)."

  use ExUnit.Case, async: true

  alias Core.Conversations.Eml
  alias Core.Inbound.Gmail

  test "the made-up check: its code and its link" do
    {:ok, mail} =
      Eml.parse(File.read!(Path.expand("../../../priv/eml/gmail-confirmation.eml", __DIR__)))

    assert Gmail.confirmation(mail) ==
             {:ok,
              %{
                code: "482915736",
                url:
                  "https://mail-settings.google.com/mail/vf-%5BANGjdJ-example-check%5D-example-token"
              }}
  end

  test "another sender is no check; the check without a code still is one" do
    assert Gmail.confirmation(%{
             from: {"Mei", "mei.chen@juniperedge.example"},
             subject: "(#123456) x"
           }) == :no

    assert Gmail.confirmation(%{
             from: {nil, "forwarding-noreply@google.com"},
             subject: "Hello",
             text: "no code"
           }) ==
             {:ok, %{code: nil, url: nil}}
  end
end
