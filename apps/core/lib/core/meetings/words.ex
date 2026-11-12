defmodule Core.Meetings.Words do
  @moduledoc """
  The meetings' words (AQ-06 §8, §12.3), **pure**: a time in a zone with
  its abbreviation ("Tue 18 Nov 14:00 PKT"), a platform ("Google Meet"),
  how long before ("in 1 hour"), the clash ("Tanweer has *Technical
  interview* (Corvid Security) from 14:00 to 15:00."). One place, so the
  ledger's frozen labels, the notifications and the clash say a thing the
  same way.
  """

  @platforms %{
    zoom: "Zoom",
    google_meet: "Google Meet",
    teams: "Teams",
    upwork: "Upwork",
    phone: "Phone",
    on_site: "On site",
    other: "Other"
  }

  @doc ~S"""
  A platform as a person reads it.

      iex> Core.Meetings.Words.platform(:google_meet)
      "Google Meet"
  """
  @spec platform(atom() | String.t()) :: String.t()
  def platform(p), do: Map.fetch!(@platforms, String.to_existing_atom(to_string(p)))

  @doc ~S"""
  An instant in `zone`, as a notice says it.

      iex> Core.Meetings.Words.at(~U[2026-11-18 09:00:00Z], "Asia/Karachi")
      "Wed 18 Nov 14:00 PKT"
      iex> Core.Meetings.Words.at(~U[2026-11-18 09:00:00Z], "Europe/Berlin")
      "Wed 18 Nov 10:00 CET"
  """
  @spec at(DateTime.t(), String.t() | nil) :: String.t()
  def at(%DateTime{} = at, zone) do
    local = local(at, zone)
    Calendar.strftime(local, "%a %-d %b %H:%M ") <> abbr(local)
  end

  @doc ~S"""
  A clock time in `zone`: "14:00".

      iex> Core.Meetings.Words.clock(~U[2026-11-18 09:00:00Z], "Asia/Karachi")
      "14:00"
  """
  @spec clock(DateTime.t(), String.t() | nil) :: String.t()
  def clock(%DateTime{} = at, zone), do: at |> local(zone) |> Calendar.strftime("%H:%M")

  @doc ~S"""
  How long before a meeting a reminder comes, from its offset in minutes.

      iex> Enum.map([1440, 60, 10], &Core.Meetings.Words.before/1)
      ["in 24 hours", "in 1 hour", "in 10 minutes"]
  """
  @spec before(pos_integer()) :: String.t()
  def before(60), do: "in 1 hour"
  def before(minutes) when rem(minutes, 60) == 0, do: "in #{div(minutes, 60)} hours"
  def before(minutes), do: "in #{minutes} minutes"

  @doc ~S"""
  The clash warning (§8.1): the customer's other meeting, named when the
  reader may see it, else "another meeting".

      iex> Core.Meetings.Words.clash("Tanweer", "Technical interview", "Corvid Security",
      ...>   {~U[2026-11-18 09:00:00Z], ~U[2026-11-18 10:00:00Z]}, "Asia/Karachi")
      "Tanweer has Technical interview (Corvid Security) from 14:00 to 15:00."
      iex> Core.Meetings.Words.clash("Tanweer", nil, nil,
      ...>   {~U[2026-11-18 09:00:00Z], ~U[2026-11-18 10:00:00Z]}, "Asia/Karachi")
      "Tanweer has another meeting from 14:00 to 15:00."
  """
  @spec clash(
          String.t(),
          String.t() | nil,
          String.t() | nil,
          {DateTime.t(), DateTime.t()},
          String.t()
        ) ::
          String.t()
  def clash(customer, title, company, {starts, ends}, zone) do
    what =
      case {title, company} do
        {nil, _company} -> "another meeting"
        {title, nil} -> title
        {title, company} -> "#{title} (#{company})"
      end

    "#{customer} has #{what} from #{clock(starts, zone)} to #{clock(ends, zone)}."
  end

  defp local(at, zone) do
    case zone && DateTime.shift_zone(at, zone) do
      {:ok, local} -> local
      _unknown -> at
    end
  end

  defp abbr(%DateTime{zone_abbr: abbr}) when abbr in [nil, ""], do: "UTC"
  defp abbr(%DateTime{zone_abbr: abbr}), do: abbr
end
