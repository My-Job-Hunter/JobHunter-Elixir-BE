defmodule Core.Conversations.Tree do
  @moduledoc """
  A conversation's tree (AQ-06 §7.1, QP6-7), **pure**: the messages in,
  the roots out (oldest first), each with its children, oldest first.

  - **The parent** of an email is `In-Reply-To`'s message, else the last of
    `References` the conversation holds (`parent/3`, JWZ's rule); by hand
    it is *Replies to*. A message whose parent is not in the set is a root.
  - **A gap** is a message replying to one the conversation does not hold
    (its `In-Reply-To`, else its last `References`, names a `Message-ID` we
    have not seen): the tree
    shows "An earlier message isn't here." above it (`parent_missing`), and
    `gaps` counts them. It closes when the parent arrives and the child is
    re-linked (`Core.Conversations.Inbox`).
  """

  @doc """
  The parent's `Message-ID` for a message with these headers, among the
  `held` ids: `In-Reply-To` when held, else the last held of `References`,
  else `nil`.

      iex> Core.Conversations.Tree.parent("b", ["a", "b"], MapSet.new(["a"]))
      "a"
      iex> Core.Conversations.Tree.parent("b", ["a", "b"], MapSet.new(["a", "b"]))
      "b"
      iex> Core.Conversations.Tree.parent(nil, [], MapSet.new(["a"]))
      nil
  """
  @spec parent(String.t() | nil, [String.t()], MapSet.t()) :: String.t() | nil
  def parent(in_reply_to, references, held) do
    if in_reply_to && MapSet.member?(held, in_reply_to),
      do: in_reply_to,
      else: references |> Enum.reverse() |> Enum.find(&MapSet.member?(held, &1))
  end

  @doc """
  Whether a message's parent is missing: it names one (`In-Reply-To`, else
  the last of `References`) that the conversation does not hold.

      iex> Core.Conversations.Tree.gap?(%{in_reply_to: "b", references: ["a", "b"]}, MapSet.new(["a"]))
      true
      iex> Core.Conversations.Tree.gap?(%{in_reply_to: nil, references: []}, MapSet.new())
      false
  """
  @spec gap?(map(), MapSet.t()) :: boolean()
  def gap?(message, held) do
    case Map.get(message, :in_reply_to) || List.last(Map.get(message, :references) || []) do
      nil -> false
      id -> not MapSet.member?(held, id)
    end
  end

  @doc """
  The roots of `messages` (maps with `id`, `parent_message_id`, `sent_at`,
  `in_reply_to`, `rfc_message_id`), each as `node.(message, children,
  parent_missing)`; and how many gaps there are.
  """
  @spec build([map()], (map(), [term()], boolean() -> term())) :: {[term()], non_neg_integer()}
  def build(messages, node) when is_function(node, 3) do
    ids = MapSet.new(messages, & &1.id)
    held = messages |> Enum.map(& &1.rfc_message_id) |> Enum.reject(&is_nil/1) |> MapSet.new()

    by_parent =
      messages
      |> Enum.sort_by(&{DateTime.to_unix(&1.sent_at, :microsecond), &1.id})
      |> Enum.group_by(fn m ->
        if m.parent_message_id && MapSet.member?(ids, m.parent_message_id),
          do: m.parent_message_id,
          else: :root
      end)

    roots = grow(Map.get(by_parent, :root, []), by_parent, held, node, MapSet.new())
    {roots, Enum.count(messages, &gap?(&1, held))}
  end

  # `seen` guards against a cycle a bad edit could make: a message is placed once.
  defp grow(level, by_parent, held, node, seen) do
    for m <- level, not MapSet.member?(seen, m.id) do
      seen = MapSet.put(seen, m.id)
      children = grow(Map.get(by_parent, m.id, []), by_parent, held, node, seen)
      node.(m, children, gap?(m, held))
    end
  end
end
