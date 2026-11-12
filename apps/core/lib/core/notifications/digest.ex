defmodule Core.Notifications.Digest do
  @moduledoc """
  What a person's daily digest says, and whether it is due (AQ-08 §7.4,
  §11.4, QP8-12). **Pure**: rows and settings in, words out.

  mCart's restraint, kept: **one a day**, at the person's time, in their
  zone, keyed by that local date (`digest:<user>:<local date>`), and
  **nothing when there is nothing to say**. AutoQare's says the person's
  unread notifications of digest kinds (tasks due, follow-ups, archive
  warnings, triage) since their last digest:
  - the title: "1 thing you haven't read" / "5 things you haven't read";
  - the body: a line per group ("Tasks · 3"), a blank line, then up to 50
    titles, oldest first, then "and 12 more".
  """

  @most 50

  @doc """
  Whether the person's digest is due at `now`: their digest time has passed
  today in their zone. Answers `{:due, local_date}` or `:not_yet`.

      iex> Core.Notifications.Digest.due(~T[08:00:00], "Asia/Karachi", ~U[2026-11-12 03:30:00Z])
      {:due, ~D[2026-11-12]}
      iex> Core.Notifications.Digest.due(~T[08:00:00], "Asia/Karachi", ~U[2026-11-12 02:30:00Z])
      :not_yet
  """
  @spec due(Time.t(), String.t() | nil, DateTime.t()) :: {:due, Date.t()} | :not_yet
  def due(%Time{} = at, zone, %DateTime{} = now) do
    local = local(now, zone)

    if Time.compare(DateTime.to_time(local), at) == :lt,
      do: :not_yet,
      else: {:due, DateTime.to_date(local)}
  end

  @doc """
  The key that makes it once a day.

      iex> Core.Notifications.Digest.key("u1", ~D[2026-11-12])
      "digest:u1:2026-11-12"
  """
  @spec key(binary(), Date.t()) :: String.t()
  def key(user_id, %Date{} = date), do: "digest:#{user_id}:#{Date.to_iso8601(date)}"

  @doc """
  The digest for `rows` (`%{title, group}`, oldest first), with `groups`
  (`%{key, label}`, in their order) naming the lines. `nil` when there is
  nothing to say.

      iex> Core.Notifications.Digest.compose([], [])
      nil
      iex> Core.Notifications.Digest.compose(
      ...>   [%{title: "Follow up on “Golang”", group: "leads"}],
      ...>   [%{key: "tasks", label: "Tasks"}, %{key: "leads", label: "Leads"}]
      ...> )
      %{title: "1 thing you haven't read", body: "Leads · 1\\n\\nFollow up on “Golang”"}
  """
  @spec compose([map()], [map()]) :: %{title: String.t(), body: String.t()} | nil
  def compose([], _groups), do: nil

  def compose(rows, groups) do
    counts = Enum.frequencies_by(rows, & &1.group)

    heads =
      for g <- groups, n = Map.get(counts, g.key), do: "#{g.label} · #{n}"

    titles = rows |> Enum.take(@most) |> Enum.map(& &1.title)
    more = length(rows) - @most
    tail = if more > 0, do: ["and #{more} more"], else: []

    %{
      title: title(length(rows)),
      body: Enum.join(heads, "\n") <> "\n\n" <> Enum.join(titles ++ tail, "\n")
    }
  end

  @doc """
  The digest's title.

      iex> Core.Notifications.Digest.title(1)
      "1 thing you haven't read"
      iex> Core.Notifications.Digest.title(5)
      "5 things you haven't read"
  """
  @spec title(pos_integer()) :: String.t()
  def title(1), do: "1 thing you haven't read"
  def title(n), do: "#{n} things you haven't read"

  defp local(now, zone) do
    case DateTime.shift_zone(now, zone || "Etc/UTC") do
      {:ok, local} -> local
      _unknown_zone -> now
    end
  end
end
