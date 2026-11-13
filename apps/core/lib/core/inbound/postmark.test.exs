defmodule Core.Inbound.PostmarkTest do
  @moduledoc "Postmark's inbound JSON, in its documented shape (`priv/eml/postmark-inbound.json`)."

  use ExUnit.Case, async: true

  alias Core.Conversations.Eml
  alias Core.Inbound.Postmark

  test "reads OriginalRecipient, MessageID and RawEmail, which P6's parser reads" do
    body =
      Jason.decode!(File.read!(Path.expand("../../../priv/eml/postmark-inbound.json", __DIR__)))

    assert {:ok, %{to: "in+abcdefghjk@inbound.autoqare.local", provider_message_id: id, raw: raw}} =
             Postmark.read(body)

    assert id == "73e6d360-66eb-11e1-8e72-a8904824019b"

    assert {:ok, %{message_id: "20261107081500.mei-4@juniperedge.example"}} =
             Eml.parse(raw)
  end

  test "without OriginalRecipient, the first ToFull, else To; nothing missing is invented" do
    assert {:ok, %{to: "a@x.example"}} =
             Postmark.read(%{
               "ToFull" => [%{"Email" => "a@x.example"}, %{"Email" => "b@x.example"}]
             })

    assert {:ok, %{to: "\"A\" <a@x.example>"}} =
             Postmark.read(%{"To" => "\"A\" <a@x.example>, b@x.example"})

    assert {:ok, %{to: nil, provider_message_id: nil, raw: nil}} = Postmark.read(%{})
  end
end
