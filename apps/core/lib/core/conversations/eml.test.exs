defmodule Core.Conversations.EmlTest do
  @moduledoc """
  AQ-06 §7.1, QP6-6: an `.eml` read with the `mail` package — the made-up
  thread's headers, multipart bodies decoded and sanitised, an attachment
  kept with its name; bare line ends and Latin-1 bytes read; anything else
  unreadable.
  """

  use ExUnit.Case, async: true

  alias Core.Conversations.Eml

  doctest Eml

  defp fixture(name), do: File.read!(Path.expand("../../../priv/eml/" <> name, __DIR__))

  test "the three made-up files: ids, threading headers, who, when, bodies, the attachment" do
    {:ok, one} = Eml.parse(fixture("thread-1.eml"))
    assert one.message_id == "20261102101500.mei-1@juniperedge.example"
    assert one.in_reply_to == nil and one.references == []
    assert one.from == {"Mei Chen", "mei.chen@juniperedge.example"}
    assert one.to == [{"Tanweer", "tanweer@example.com"}]
    assert one.sent_at == ~U[2026-11-02 02:15:00Z]
    assert one.text =~ "close fit — would you be open"
    refute one.html =~ "<script"

    {:ok, two} = Eml.parse(fixture("thread-2.eml"))
    assert two.in_reply_to == one.message_id and two.references == [one.message_id]

    assert [
             %{
               filename: "role-summary.txt",
               content_type: "text/plain",
               bytes: "Platform Engineer" <> _
             }
           ] = two.attachments

    {:ok, three} = Eml.parse(fixture("thread-3.eml"))
    assert three.references == [one.message_id, two.message_id]
    assert three.in_reply_to == two.message_id
  end

  test "bare line ends and an 8-bit Latin-1 body read; a text body from the HTML; garbage is unreadable" do
    raw =
      "From: Ren\xe9 <rene@example.com>\nSubject: Caf\xe9\nContent-Type: text/html; charset=iso-8859-1\n\n<p>Bonjour, caf\xe9</p>"

    assert {:ok, %{from: {"René", "rene@example.com"}, subject: "Café", text: "Bonjour, café"}} =
             Eml.parse(raw)

    assert Eml.parse("not an email at all") == {:error, :unreadable}
  end
end
