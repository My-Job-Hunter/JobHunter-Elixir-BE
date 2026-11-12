defmodule Core.Ingest.Extension.Words do
  @moduledoc """
  The banner the side panel shows over a job (AQ-05 §10.5, §11.4, QP5-19),
  **worded by the server**, so the extension holds no copy of the wording
  and the words can change any day. `{tone, words}`, `tone` ∈ `ok · info ·
  warn · refused`; **the lead half's answer wins over the job's**.

  | Case | Tone | Words |
  |---|---|---|
  | not a job (`invalid`) | `info` | "This page isn't a job we can read." |
  | new | `ok` | "New job." |
  | new, with a similar posting | `warn` | "Similar posting: “Staff Engineer” · Madrid · 2 d ago." |
  | in the pool | `ok` | "In the pool, first seen 3 Nov." |
  | in the pool, a teammate's the caller may not see | `info` | "That link is already in this team's pool, added by another member." |
  | `warn` | `warn` | "Naveed applied as “Elixir backend” on 12 Oct (Fiza)." · "…on 12 Oct, in another team." |
  | `saved` | `info` | "Already saved for “Golang” by Fiza, 12 Oct." · "…by another member, 12 Oct." |
  | `refused` | `refused` | "Already applied as “Golang” by Fiza, 12 Oct. Now: In progress · Technical interview 1." · a purged lead: the guard's tombstone words |
  | `elsewhere` | `refused` | "“Golang” already has a lead on this job in another team (applied 12 Oct). That team carries it." |

  The document's *emphasis* is the house's curly quotes
  (`Core.Leads.Words.quoted/1`), as the 409s say it. Days are the
  organisation's (`Core.Leads.Words.day/2`).
  """

  alias Core.Leads.Guard
  alias Core.Leads.Words

  @hidden "That link is already in this team's pool, added by another member."

  @doc """
  The banner for a lookup: the check's answer (`Core.Jobs.Check.run/3`),
  the guard's assessment for the acting profile (or `nil`), and `ctx`:
  `%{scope, profile, team_id, zone, now}`.
  """
  @spec banner(map(), map() | nil, map()) :: %{tone: String.t(), words: String.t()}
  def banner(%{state: "invalid"}, _guard, _ctx),
    do: %{tone: "info", words: "This page isn't a job we can read."}

  def banner(_check, %{answer: answer} = guard, ctx)
      when answer in ~w(warn saved refused elsewhere),
      do: lead(answer, guard, ctx)

  def banner(check, _guard, ctx), do: job(check, ctx)

  # ── The job half ────────────────────────────────────────────────────────────

  defp job(%{state: "in_pool", hidden: true}, _ctx), do: %{tone: "info", words: @hidden}

  defp job(%{state: "in_pool", job: job}, ctx),
    do: %{tone: "ok", words: "In the pool, first seen #{Words.day(job.first_seen_at, ctx.zone)}."}

  defp job(%{state: "new", similar: [similar | _rest]}, ctx) do
    parts =
      [Words.quoted(similar.title), where(similar), age(similar.first_seen_at, ctx.now)]
      |> Enum.reject(&is_nil/1)

    %{tone: "warn", words: "Similar posting: " <> Enum.join(parts, " · ") <> "."}
  end

  defp job(_new, _ctx), do: %{tone: "ok", words: "New job."}

  defp where(%{onsite_locations: [place | _rest]}) when is_binary(place), do: place
  defp where(%{workplace: workplace}) when workplace in [:remote, "remote"], do: "Remote"
  defp where(_row), do: nil

  defp age(nil, _now), do: nil

  defp age(at, now) do
    case div(DateTime.diff(now, at, :second), 86_400) do
      days when days < 1 -> "today"
      days -> "#{days} d ago"
    end
  end

  # ── The lead half ───────────────────────────────────────────────────────────

  defp lead("warn", guard, ctx) do
    other = List.first(guard.same_customer) || %{}
    who = first(ctx.profile.customer.display_name)
    title = Words.quoted(get_in(other, [:profile, :title]) || "")
    day = Words.day(other[:applied_at], ctx.zone)
    by = if name = get_in(other, [:by, :name]), do: " (#{first(name)})", else: ""

    words =
      case {day, other[:team]} do
        {nil, "another"} -> "#{who} has a lead as #{title} on this job, in another team."
        {nil, _here} -> "#{who} has a lead as #{title} on this job#{by}."
        {day, "another"} -> "#{who} applied as #{title} on #{day}, in another team."
        {day, _here} -> "#{who} applied as #{title} on #{day}#{by}."
      end

    %{tone: "warn", words: words}
  end

  defp lead("saved", guard, ctx) do
    %{tone: "info", words: "Already saved for #{mine(ctx)} by #{by(guard)}#{when_(guard, ctx)}."}
  end

  defp lead("refused", %{existing: %{purged: true}, fingerprint: tomb}, ctx)
       when not is_nil(tomb) do
    {:duplicate_application, %{message: message}} =
      Guard.tombstone(ctx.scope, tomb, ctx.team_id, ctx.profile)

    %{tone: "refused", words: message}
  end

  defp lead("refused", guard, ctx) do
    lead = guard.lead
    verb = if lead && lead.applied_at, do: "Already applied as", else: "Already saved for"
    now = now_words(guard)

    %{tone: "refused", words: "#{verb} #{mine(ctx)} by #{by(guard)}#{when_(guard, ctx)}.#{now}"}
  end

  defp lead("elsewhere", guard, ctx) do
    applied =
      case Words.day(guard.existing && guard.existing[:applied_at], ctx.zone) do
        nil -> ""
        day -> " (applied #{day})"
      end

    %{
      tone: "refused",
      words:
        "#{mine(ctx)} already has a lead on this job in another team#{applied}. " <>
          "That team carries it."
    }
  end

  defp mine(ctx), do: Words.quoted(ctx.profile.title)

  # Whoever the guard may name (P4a: whoever applied, else saved, else owns
  # it), or "another member" when the caller may not see the lead.
  defp by(%{existing: %{by: %{name: name}}}) when is_binary(name), do: first(name)
  defp by(_guard), do: "another member"

  # The day it was applied, else saved.
  defp when_(%{lead: %{} = lead}, ctx) do
    case Words.day(lead.applied_at || lead.inserted_at, ctx.zone) do
      nil -> ""
      day -> ", " <> day
    end
  end

  defp when_(_guard, _ctx), do: ""

  # "Now: In progress · Technical interview 1.", for a lead the caller sees.
  defp now_words(%{existing: %{state: state} = existing, lead: %{} = lead})
       when not is_nil(state) do
    stage = get_in(existing, [:stage, :name])

    case Words.place(state, stage, lead.outcome) do
      nil -> ""
      place -> " Now: " <> place <> "."
    end
  end

  defp now_words(_guard), do: ""

  defp first(nil), do: "This customer"
  defp first(name), do: name |> String.split(" ", trim: true) |> List.first() || name
end
