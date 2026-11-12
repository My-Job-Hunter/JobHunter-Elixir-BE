defmodule Core.Leads.Words do
  @moduledoc """
  The leads' words (AQ-04A §11.3), **pure**: a state, an outcome, a lead's
  place ("In progress · Technical interview 1"), a day ("12 Oct"), the
  job's "title · company". One place, so the ledger's frozen labels, the
  notifications and the 409's messages say a thing the same way.
  """

  @states %{todo: "To do", in_progress: "In progress", on_hold: "On hold", done: "Done"}

  @outcomes %{
    hired: "Hired",
    rejected: "Rejected",
    withdrawn: "Withdrawn",
    position_closed: "Position closed",
    no_response: "No response",
    not_pursued: "Not pursued"
  }

  # A job's source, workplace and engagement as a person reads them: the
  # console's spelling (`@aq/core`'s `labels.js`, kept equal by hand for
  # these lists), else the words with the first capitalised.
  @values %{
    linkedin: "LinkedIn",
    upwork: "Upwork",
    indeed: "Indeed",
    fiverr: "Fiverr",
    yc_waas: "YC Work at a Startup",
    wellfound: "Wellfound",
    greenhouse: "Greenhouse",
    lever: "Lever",
    ashby: "Ashby",
    workable: "Workable",
    company_site: "Company site",
    email: "Email",
    on_site: "On site",
    full_time: "Full time",
    part_time: "Part time",
    freelance_hourly: "Freelance, hourly",
    freelance_fixed: "Freelance, fixed price"
  }

  @doc ~S"""
  A source, workplace or engagement value as a person reads it (the CSV, a
  group's head).

      iex> Core.Leads.Words.value(:company_site)
      "Company site"
      iex> Core.Leads.Words.value("remote")
      "Remote"
      iex> Core.Leads.Words.value(nil)
      nil
  """
  @spec value(atom() | String.t() | nil) :: String.t() | nil
  def value(nil), do: nil

  def value(value) do
    key = to_string(value)

    Enum.find_value(@values, fn {k, words} -> if Atom.to_string(k) == key, do: words end) ||
      key |> String.replace("_", " ") |> String.capitalize()
  end

  @doc "A state as the board says it."
  @spec state(atom() | String.t() | nil) :: String.t() | nil
  def state(nil), do: nil
  def state(value), do: Map.fetch!(@states, atomize(value))

  @doc "An outcome as the board says it."
  @spec outcome(atom() | String.t() | nil) :: String.t() | nil
  def outcome(nil), do: nil
  def outcome(value), do: Map.fetch!(@outcomes, atomize(value))

  @doc ~S"""
  Where a lead stands, in words: the state, with the stage in progress and
  on hold, the outcome in Done.

      iex> Core.Leads.Words.place(:in_progress, "Technical interview 1", nil)
      "In progress · Technical interview 1"
      iex> Core.Leads.Words.place(:done, "Technical interview 2", :rejected)
      "Rejected · Technical interview 2"
      iex> Core.Leads.Words.place(:todo, nil, nil)
      "To do"
  """
  @spec place(atom(), String.t() | nil, atom() | nil) :: String.t()
  def place(:done, nil, outcome), do: outcome(outcome)
  def place(:done, stage, outcome), do: outcome(outcome) <> " · " <> stage
  def place(state, nil, _outcome), do: state(state)
  def place(state, stage, _outcome), do: state(state) <> " · " <> stage

  @doc ~s(A day as a banner says it, in `zone`: "12 Oct".)
  @spec day(DateTime.t() | nil, String.t()) :: String.t() | nil
  def day(nil, _zone), do: nil

  def day(%DateTime{} = at, zone) do
    local =
      case DateTime.shift_zone(at, zone) do
        {:ok, local} -> local
        _unknown -> at
      end

    Calendar.strftime(local, "%-d %b")
  end

  @doc ~S"""
  A job as a notification names it: "“Backend Developer · Bamboo Invest”".

      iex> Core.Leads.Words.job(%{title: "Backend Developer", company: %{name: "Bamboo Invest"}})
      "“Backend Developer · Bamboo Invest”"
      iex> Core.Leads.Words.job(%{title: "Backend Developer", company: nil})
      "“Backend Developer”"
  """
  @spec job(map()) :: String.t()
  def job(%{title: title, company: %{name: name}}), do: quoted(title <> " · " <> name)
  def job(%{title: title}), do: quoted(title)

  @doc ~S"""
  A job as the customer's line names it: "“Backend Developer” at Bamboo Invest".

      iex> Core.Leads.Words.job_at(%{title: "Backend Developer", company: %{name: "Bamboo Invest"}})
      "“Backend Developer” at Bamboo Invest"
  """
  @spec job_at(map()) :: String.t()
  def job_at(%{title: title, company: %{name: name}}), do: quoted(title) <> " at " <> name
  def job_at(%{title: title}), do: quoted(title)

  @doc "A title as a line quotes it."
  def quoted(text), do: "“" <> text <> "”"

  defp atomize(value) when is_atom(value), do: value
  defp atomize(value) when is_binary(value), do: String.to_existing_atom(value)
end
