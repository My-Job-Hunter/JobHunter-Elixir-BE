defmodule Core.Inbound.Postmark do
  @moduledoc """
  Postmark's inbound webhook, read (AQ-09 §6.2, §11.4, QP9-2), **pure**:
  the JSON it posts, with *Include raw email content* on, in; what the
  intake needs out — the address it came to (`OriginalRecipient`, else
  the first `ToFull[].Email`, else `To`), Postmark's own id (`MessageID`,
  the retry key) and the raw message (`RawEmail`), which P6's parser reads
  as it reads an upload. Every other field is ignored: the raw bytes keep
  every header threading needs. A provider swap is another module of this
  shape.
  """

  @doc """
  `{:ok, %{to, provider_message_id, raw}}`; any of them `nil` when the
  body doesn't carry it (the intake logs that as `unreadable` or
  `unknown_address`).
  """
  @spec read(map()) ::
          {:ok,
           %{to: String.t() | nil, provider_message_id: String.t() | nil, raw: binary() | nil}}
  def read(%{} = body) do
    {:ok,
     %{
       to: to(body),
       provider_message_id: text(body["MessageID"]),
       raw: raw(body["RawEmail"])
     }}
  end

  defp to(body) do
    text(body["OriginalRecipient"]) || first_to(body["ToFull"]) || first_plain(body["To"])
  end

  defp first_to([%{"Email" => email} | _rest]), do: text(email)
  defp first_to(_none), do: nil

  defp first_plain(to) when is_binary(to), do: to |> String.split(",") |> hd() |> text()
  defp first_plain(_none), do: nil

  defp raw(raw) when is_binary(raw) and raw != "", do: raw
  defp raw(_none), do: nil

  defp text(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp text(_value), do: nil
end
