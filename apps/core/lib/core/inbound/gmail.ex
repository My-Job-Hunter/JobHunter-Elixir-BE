defmodule Core.Inbound.Gmail do
  @moduledoc """
  Gmail's forwarding confirmation recognised (AQ-09 §8, QP9-11), **pure**.
  Gmail won't forward until the address confirms: it mails a code and a
  link from `forwarding-noreply@google.com`. A mail from that sender is
  the check, never a conversation; its code is read from the subject's
  `(#123456789)` or the body's "Confirmation code: 123456789", its link
  is the body's first Google link to a `vf-` page (else the first Google
  link).
  """

  @sender "forwarding-noreply@google.com"

  @doc "The sender Gmail's check comes from."
  def sender, do: @sender

  @doc """
  `{:ok, %{code, url}}` when `mail` (P6's parsed shape) is Gmail's check,
  else `:no`. A check with neither a code nor a link is still the check
  (nothing to show, never filed).
  """
  @spec confirmation(map()) :: {:ok, %{code: String.t() | nil, url: String.t() | nil}} | :no
  def confirmation(%{from: {_name, @sender}} = mail) do
    text = Enum.join([mail[:subject] || "", mail[:text] || "", mail[:html] || ""], "\n")
    {:ok, %{code: code(mail[:subject], text), url: url(text)}}
  end

  def confirmation(_mail), do: :no

  defp code(subject, text) do
    from_subject = subject && Regex.run(~r/\(#\s*(\d{4,12})\)/, subject, capture: :all_but_first)
    from_body = Regex.run(~r/confirmation code:?\s*(\d{4,12})/i, text, capture: :all_but_first)

    case from_subject || from_body do
      [code] -> code
      _none -> nil
    end
  end

  defp url(text) do
    links =
      ~r{https://[a-z0-9.-]*google\.com/[^\s"'<>]+}i
      |> Regex.scan(text)
      |> List.flatten()
      |> Enum.map(&String.trim_trailing(&1, "."))

    Enum.find(links, &String.contains?(&1, "/vf-")) || List.first(links)
  end
end
