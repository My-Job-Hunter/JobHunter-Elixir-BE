defmodule Core.Tasks.Words do
  @moduledoc """
  The board's words (AQ-02 §8, §10.3), **pure**: labels for states and the
  rest, a person's first name, who is "on it", and the frozen titles of the
  notifications. One place, so the history, the notifications and the
  409's message say a state the same way.
  """

  @states %{
    draft: "Draft",
    todo: "To do",
    in_progress: "In progress",
    on_hold: "On hold",
    done: "Done",
    closed: "Closed"
  }

  @priorities %{nil => "Normal", low: "Low", high: "High", urgent: "Urgent"}
  @reminders %{0 => "At the time", 60 => "1 hour before", 1440 => "1 day before"}

  @relations %{relates_to: "Relates to", blocks: "Blocks", duplicates: "Duplicates"}

  @doc "A state as the board says it: `:in_progress` → \"In progress\"."
  @spec state(atom() | String.t() | nil) :: String.t() | nil
  def state(nil), do: nil
  def state(value), do: Map.fetch!(@states, atomize(value))

  @doc "A priority; none is \"Normal\"."
  def priority(value), do: Map.fetch!(@priorities, value && atomize(value))

  @doc "A reminder choice."
  def reminder(nil), do: nil
  def reminder(minutes), do: Map.fetch!(@reminders, minutes)

  @doc "How two tasks relate, from the end that made it."
  def relation(kind), do: Map.fetch!(@relations, atomize(kind))

  @doc ~s(A due as it reads in the activity, in `zone`: "12 Nov 2026" or "12 Nov 2026, 15:00".)
  @spec due(DateTime.t() | Date.t() | nil, String.t()) :: String.t() | nil
  def due(nil, _zone), do: nil
  def due(%Date{} = on, _zone), do: Calendar.strftime(on, "%-d %b %Y")

  def due(%DateTime{} = at, zone) do
    at |> local(zone) |> Calendar.strftime("%-d %b %Y, %H:%M")
  end

  @doc "The time of day of `at` in `zone`: \"15:00\"."
  def clock(%DateTime{} = at, zone), do: at |> local(zone) |> Calendar.strftime("%H:%M")

  defp local(at, zone) do
    case DateTime.shift_zone(at, zone) do
      {:ok, local} -> local
      _unknown -> at
    end
  end

  @doc "A person's first name: the given name, else the first word of the display name."
  @spec first_name(map() | nil) :: String.t() | nil
  def first_name(nil), do: nil
  def first_name(%{given_name: given}) when is_binary(given) and given != "", do: given

  def first_name(%{display_name: name}) when is_binary(name),
    do: name |> String.split(" ", trim: true) |> List.first() || name

  def first_name(_person), do: nil

  @doc ~S"""
  Who is on a task, in the customer's words: `nil` with nobody, "The team"
  when the team hides names, else the first names joined.

      iex> Core.Tasks.Words.on_it(["Fiza", "Qasim"], true)
      "Fiza and Qasim"
      iex> Core.Tasks.Words.on_it(["Fiza"], false)
      "The team"
  """
  @spec on_it([String.t()], boolean()) :: String.t() | nil
  def on_it([], _names?), do: nil
  def on_it(_names, false), do: "The team"
  def on_it(names, true), do: join(names)

  @doc ~S"""
  A list said in English.

      iex> Core.Tasks.Words.join(["Fiza", "Qasim", "Hira"])
      "Fiza, Qasim and Hira"
  """
  def join([]), do: ""
  def join([one]), do: one
  def join(names), do: Enum.join(Enum.drop(names, -1), ", ") <> " and " <> List.last(names)

  @doc "A task or step title as a notification quotes it."
  def quoted(title), do: "“" <> title <> "”"

  @doc "The first `n` characters of a comment, on one line."
  @spec excerpt(String.t(), pos_integer()) :: String.t()
  def excerpt(body, n \\ 140) do
    said = body |> String.replace(~r/\s+/, " ") |> String.trim()
    if String.length(said) > n, do: String.slice(said, 0, n) <> "…", else: said
  end

  defp atomize(value) when is_atom(value), do: value
  defp atomize(value) when is_binary(value), do: String.to_existing_atom(value)
end
