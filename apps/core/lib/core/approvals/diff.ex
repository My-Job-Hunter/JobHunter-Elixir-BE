defmodule Core.Approvals.Diff do
  @moduledoc """
  What changed between two versions (AQ-07 §6, QP7-8), **pure** and
  computed on read: **word by word** for the body and each proposed text
  (`title`, `headline`, `summary`), and **old → new** for the values that
  are not prose (the CV, the bid, Connects, the expectation, the skills).

  Shape (§11.4): `[%{field, parts: [%{op: "same" | "added" | "removed",
  text}]}]`, one entry per field that changed, in a fixed order; nothing
  for a field that is the same in both.
  """

  @prose ~w(body_md title headline summary)a
  @values ~w(document bid connects expectation skills)a
  @order ~w(body_md document bid connects expectation title headline summary skills)a

  @doc """
  The diff from `before` to `now`, each a map of the fields above to text
  (or `nil`): prose as written, values already in words ("USD 45 / hour").
  """
  @spec between(map(), map()) :: [map()]
  def between(before, now) do
    Enum.flat_map(@order, fn field ->
      {old, new} = {Map.get(before, field), Map.get(now, field)}

      if normal(old) == normal(new),
        do: [],
        else: [%{field: to_string(field), parts: parts(field, old, new)}]
    end)
  end

  defp parts(field, old, new) when field in @prose, do: words(old || "", new || "")

  defp parts(field, old, new) when field in @values do
    [removed(old), added(new)] |> Enum.reject(&is_nil/1)
  end

  defp removed(nil), do: nil
  defp removed(text), do: %{op: "removed", text: text}
  defp added(nil), do: nil
  defp added(text), do: %{op: "added", text: text}

  @doc ~S"""
  A word diff of two texts, whitespace kept with the words, runs merged.

      iex> Core.Approvals.Diff.words("rate 45 an hour", "rate 50 an hour")
      [
        %{op: "same", text: "rate "},
        %{op: "removed", text: "45"},
        %{op: "added", text: "50"},
        %{op: "same", text: " an hour"}
      ]
  """
  @spec words(String.t(), String.t()) :: [map()]
  def words(old, new) do
    old
    |> tokens()
    |> List.myers_difference(tokens(new))
    |> Enum.map(fn {op, toks} -> %{op: op(op), text: Enum.join(toks)} end)
    |> Enum.reject(&(&1.text == ""))
  end

  defp op(:eq), do: "same"
  defp op(:del), do: "removed"
  defp op(:ins), do: "added"

  defp tokens(text), do: Regex.split(~r/(\s+)/u, text, include_captures: true, trim: true)

  defp normal(nil), do: nil
  defp normal(text) when is_binary(text), do: String.trim(text)
  defp normal(other), do: other
end
