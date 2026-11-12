defmodule Core.Ingest.Extension.Normalize do
  @moduledoc """
  The adapter's raw strings into P3's fields (AQ-05 §10.1, QP5-12),
  **pure**: one rule, one home. The extension reads; the server decides
  what the words mean, so a parser fix is a deploy, not a store release.

  | Raw | Becomes |
  |---|---|
  | `title`, `company_name`, `company_url` | the title; the company by name (a `linkedin.com/company/…` link is its `linkedin_url`, any other its `website_url`) |
  | `workplace_text`, `location_text` | `workplace`; `onsite_locations` on site or hybrid; remote: `remote_scope` with `allowed_countries` or `allowed_regions` ("Remote (US)" → `country_list`, `US`) |
  | `employment_text`; Upwork's rate or budget | `engagement` ("Volunteer" → `other`; Upwork → `freelance_hourly` / `freelance_fixed`) |
  | `seniority_text`; `upwork.experience_text` | LinkedIn's `seniority`; Upwork's `experience_level` on its details |
  | `salary_text`; `upwork.rate_text`, `upwork.budget_text` | `comp_*` (`Core.Ingest.Extension.Money`), `comp_text` as written; `parsed_text`, or `employer` for an Upwork client's own figure |
  | `posted_text` | `posted_on` from the capture's day, in the organisation's zone; `is_reposted` |
  | `applicants_text`; Upwork's activity lines | the signals (`Core.Ingest.Extension.Facts`) |
  | `apply_kind`, `apply_url` | `apply_method` (`in_platform_easy` · `external_ats` · `proposal`; Upwork's is a proposal), `apply_url` |
  | `skills_text` | matched to the skills vocabulary by name; the rest `unmatched_skills` |
  | `description_html` | sanitised HTML (`html_sanitize_ex`) and its plain text (`description_md`) |
  | Upwork's client lines; LinkedIn's applicants and flags | the platform details (`Core.Ingest.Extension.Facts`) |
  | `bid_text`, `connects_spent_text` | the application's bid and Connects |
  | **all of them, as sent** | the snapshot's body: canonical JSON without `captured_at` |

  AQ-05 §11.4's vectors are `Core.Ingest.Extension.NormalizeTest`, one
  test each. A text nobody can read becomes nothing, never a guess.
  """

  alias Core.Ingest.Extension.{Facts, Money, Read}

  @type opts :: %{
          required(:site) => :linkedin | :upwork,
          required(:now) => DateTime.t(),
          required(:zone) => String.t(),
          optional(:skills) => [%{id: binary(), name: String.t()}]
        }

  @regions [
    {~r/\bemea\b/i, "emea"},
    {~r/\bapac\b/i, "apac"},
    {~r/\blatam\b|latin america/i, "latam"},
    {~r/north america/i, "north_america"},
    {~r/\beu\b|european union/i, "eu"},
    {~r/\beurope\b/i, "europe"},
    {~r/\bmena\b|middle east/i, "mena"},
    {~r/south asia/i, "south_asia"}
  ]

  @workplaces [
    {~r/remote/i, "remote"},
    {~r/hybrid/i, "hybrid"},
    {~r/on[\s-]?site/i, "on_site"}
  ]

  @engagements [
    {~r/full[\s-]?time/i, "full_time"},
    {~r/part[\s-]?time/i, "part_time"},
    {~r/contract/i, "contract"},
    {~r/temporary/i, "temporary"},
    {~r/internship/i, "internship"},
    {~r/volunteer/i, "other"}
  ]

  @seniorities [
    {~r/^entry/i, "entry"},
    {~r/^associate/i, "associate"},
    {~r/^mid[\s-]*senior/i, "mid_senior"},
    {~r/^director/i, "director"},
    {~r/^executive/i, "executive"},
    {~r/^internship/i, "internship"},
    {~r/^not applicable/i, "not_applicable"}
  ]

  @durations [
    {~r/less than (a|1|one) month/i, "lt_1m"},
    {~r/1 to 3 months/i, "1_3m"},
    {~r/3 to 6 months/i, "3_6m"},
    {~r/more than 6 months/i, "gt_6m"}
  ]

  defdelegate salary(text), to: Money
  defdelegate bid(text), to: Money
  defdelegate spent_band(text), to: Money
  defdelegate applicants(text), to: Facts
  defdelegate proposals(text), to: Facts
  defdelegate experience(text), to: Facts
  defdelegate integer(text), to: Read

  @doc """
  Connects as written ("Send a proposal for: 16 Connects", "16"), or `nil`.

      iex> Core.Ingest.Extension.Normalize.connects("Required Connects to submit a proposal: 16")
      16
  """
  @spec connects(String.t() | nil) :: non_neg_integer() | nil
  def connects(text), do: Read.integer(text)

  # ── The whole capture ───────────────────────────────────────────────────────

  @doc """
  A capture's `fields` (§11.3, string keys, every member possibly `nil`)
  as `%{job, company, description_html, details, signal, skills,
  unmatched_skills, bid, connects_spent, snapshot}`:

  - `job` — the job body `Core.Jobs` takes (string keys, P3's columns),
    only what was read;
  - `details` — the source's platform details, only what was read;
  - `signal` — the facts read, with `slack_s` (how precisely
    `client_last_viewed_at` was read), or `nil`;
  - `snapshot` — `%{body, captured_at}`.
  """
  @spec run(map(), opts()) :: map()
  def run(fields, %{site: site} = opts) when is_map(fields) do
    upwork = Read.sub(fields, "upwork")
    {skills, unmatched} = skills(fields["skills_text"], Map.get(opts, :skills, []))
    {html, plain} = description(fields["description_html"])
    engagement = engagement(Read.text(fields, "employment_text"), upwork, site)
    method = apply_method(Read.text(fields, "apply_kind"), site)

    %{
      job:
        job(fields, upwork, site, opts, %{
          engagement: engagement,
          method: method,
          plain: plain,
          skills: skills
        }),
      company: company(Read.text(fields, "company_name"), Read.text(fields, "company_url")),
      description_html: html,
      details: Facts.details(site, fields, method && method == "in_platform_easy"),
      signal: Facts.signal(fields, opts.now),
      skills: skills,
      unmatched_skills: unmatched,
      bid: Money.bid(Read.text(fields, "bid_text")),
      connects_spent: connects(Read.text(fields, "connects_spent_text")),
      snapshot: %{body: snapshot_body(fields), captured_at: captured_at(fields, opts.now)}
    }
  end

  defp job(fields, upwork, site, opts, read) do
    %{
      "title" => fields |> Read.text("title") |> then(&(&1 && String.slice(&1, 0, 300))),
      "engagement" => read.engagement,
      "seniority" => site == :linkedin && seniority(Read.text(fields, "seniority_text")),
      "description_md" => read.plain,
      "apply_method" => read.method,
      "apply_url" => Read.link(Read.text(fields, "apply_url")),
      "duration" => Read.first_match(Read.text(upwork, "duration_text"), @durations),
      "skills" => Enum.map(read.skills, &%{"skill_id" => &1})
    }
    |> Map.merge(
      place(Read.text(fields, "workplace_text"), Read.text(fields, "location_text"), site)
    )
    |> Map.merge(money(fields, upwork, site, read.engagement))
    |> Map.merge(posted(Read.text(fields, "posted_text"), opts))
    |> Map.merge(hours(Read.text(upwork, "hours_text")))
    |> Enum.reject(fn {_k, v} -> v in [nil, false, []] end)
    |> Map.new()
  end

  # ── The company, the place, the engagement, the seniority ───────────────────

  defp company(nil, _url), do: nil

  defp company(name, url) do
    url = Read.link(url)

    cond do
      is_nil(url) ->
        %{"name" => name}

      url =~ ~r{^https?://([a-z]+\.)?linkedin\.com/company/}i ->
        %{"name" => name, "linkedin_url" => url}

      url =~ ~r{linkedin\.com|upwork\.com}i ->
        %{"name" => name}

      true ->
        %{"name" => name, "website_url" => url}
    end
  end

  @doc """
  Where the work is: `%{"workplace", "onsite_locations", "remote_scope",
  "allowed_countries", "allowed_regions"}`, what could be read of them.

      iex> Core.Ingest.Extension.Normalize.place("Remote", "Remote (US)", :linkedin)
      %{"workplace" => "remote", "remote_scope" => "country_list", "allowed_countries" => ["US"]}
  """
  @spec place(String.t() | nil, String.t() | nil, atom()) :: map()
  def place(workplace_text, location_text, site) do
    workplace =
      Read.first_match(workplace_text, @workplaces) || located(location_text) ||
        if(site == :upwork, do: "remote")

    case {workplace, location_text && strip_place_words(location_text)} do
      {nil, _location} -> %{}
      {kind, nil} -> %{"workplace" => kind}
      {"remote", location} -> Map.put(remote_scope(location), "workplace", "remote")
      {kind, location} -> %{"workplace" => kind, "onsite_locations" => [location]}
    end
  end

  # "Remote (US)", "London (Hybrid)": a place that says how.
  defp located(nil), do: nil

  defp located(location) do
    Read.first_match(location, [
      {~r/\bremote\b/i, "remote"},
      {~r/\bhybrid\b/i, "hybrid"},
      {~r/on[\s-]?site/i, "on_site"}
    ])
  end

  defp strip_place_words(location) do
    location
    |> String.replace(~r/\((remote|hybrid|on[\s-]?site)\)/i, "")
    |> String.replace(~r/^\s*(remote|hybrid|on[\s-]?site)\s*[-–·,:]?\s*/i, "")
    |> String.trim()
    |> then(&if(&1 == "", do: nil, else: &1))
  end

  # "(US)", "United States", "Worldwide", "EMEA": the scope a remote job names.
  defp remote_scope(location) do
    inside =
      case Regex.run(~r/\(([^)]+)\)/, location) do
        [_all, inside] -> inside
        nil -> location
      end

    codes = Read.countries(inside)
    region = Read.first_match(inside, @regions)

    cond do
      inside =~ ~r/worldwide|anywhere|global/i -> %{"remote_scope" => "global"}
      codes != [] -> %{"remote_scope" => "country_list", "allowed_countries" => codes}
      region -> %{"remote_scope" => "region", "allowed_regions" => [region]}
      true -> %{}
    end
  end

  @doc """
  How it pays and binds: LinkedIn's employment type, or Upwork's hourly or
  fixed price.

      iex> Core.Ingest.Extension.Normalize.engagement("Full-time", %{}, :linkedin)
      "full_time"
      iex> Core.Ingest.Extension.Normalize.engagement("Fixed-price", %{}, :upwork)
      "freelance_fixed"
  """
  @spec engagement(String.t() | nil, map(), atom()) :: String.t() | nil
  def engagement(employment, upwork, :upwork) do
    rate = Read.text(upwork, "rate_text")
    budget = Read.text(upwork, "budget_text")
    said = [employment, rate, budget] |> Enum.reject(&is_nil/1) |> Enum.join(" ")

    cond do
      said =~ ~r/hourly/i -> "freelance_hourly"
      said =~ ~r/fixed/i -> "freelance_fixed"
      rate -> "freelance_hourly"
      budget -> "freelance_fixed"
      true -> nil
    end
  end

  def engagement(employment, _upwork, _site), do: Read.first_match(employment, @engagements)

  @doc """
  LinkedIn's seniority ladder.

      iex> Core.Ingest.Extension.Normalize.seniority("Mid-Senior level")
      "mid_senior"
  """
  @spec seniority(String.t() | nil) :: String.t() | nil
  def seniority(text), do: Read.first_match(text, @seniorities)

  defp hours(nil), do: %{}

  defp hours(text) do
    n = Read.integer(text)

    cond do
      is_nil(n) -> %{}
      text =~ ~r/less than/i -> %{"hours_max" => n}
      text =~ ~r/more than/i -> %{"hours_min" => n}
      true -> %{}
    end
  end

  defp apply_method(kind, site) do
    case kind && String.downcase(kind) do
      k when k in ["easy", "easy_apply", "in_platform_easy"] -> "in_platform_easy"
      k when k in ["external", "company_site", "external_ats"] -> "external_ats"
      "proposal" -> "proposal"
      _none -> if site == :upwork, do: "proposal", else: nil
    end
  end

  # LinkedIn's salary as read (`parsed_text`); Upwork's rate or budget, the
  # client's own figure (`employer`). Nothing read, nothing set.
  defp money(fields, upwork, :upwork, engagement) do
    hourly? = engagement == "freelance_hourly"
    rate = Read.text(upwork, "rate_text")
    budget = Read.text(upwork, "budget_text")

    said =
      if(hourly?, do: rate || budget, else: budget || rate) || Read.text(fields, "salary_text")

    Money.comp(said, if(hourly?, do: "hour", else: "project"), "employer")
  end

  defp money(fields, _upwork, _site, _engagement) do
    case Money.salary(Read.text(fields, "salary_text")) do
      nil -> %{}
      salary -> Money.comp(salary.text, salary.period, "parsed_text")
    end
  end

  # ── When ────────────────────────────────────────────────────────────────────

  @doc """
  When it was posted, from the capture's day: `%{"posted_on", "is_reposted"}`.

      iex> Core.Ingest.Extension.Normalize.posted("Reposted 1 week ago", %{now: ~U[2026-11-11 09:00:00Z], zone: "Etc/UTC"})
      %{"posted_on" => ~D[2026-11-04], "is_reposted" => true}
  """
  @spec posted(String.t() | nil, map()) :: map()
  def posted(nil, _opts), do: %{}

  def posted(text, %{now: now, zone: zone}) do
    reposted = text =~ ~r/reposted/i

    case Read.ago(text, now) do
      {at, _slack} -> %{"posted_on" => Read.local_day(at, zone), "is_reposted" => reposted}
      nil -> if reposted, do: %{"is_reposted" => true}, else: %{}
    end
  end

  defp captured_at(fields, now) do
    with at when is_binary(at) <- fields["captured_at"],
         {:ok, at, _offset} <- DateTime.from_iso8601(at),
         false <- DateTime.after?(at, now) do
      at
    else
      _other -> now
    end
  end

  # ── Skills, the description ─────────────────────────────────────────────────

  defp skills(list, vocabulary) when is_list(list) do
    by_name = Map.new(vocabulary, &{normal(&1.name), &1.id})

    {found, missed} =
      list
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq_by(&normal/1)
      |> Enum.split_with(&Map.has_key?(by_name, normal(&1)))

    {found |> Enum.map(&Map.fetch!(by_name, normal(&1))) |> Enum.uniq(), missed}
  end

  defp skills(_none, _vocabulary), do: {[], []}

  defp normal(name),
    do: name |> String.downcase() |> String.replace(~r/\s+/u, " ") |> String.trim()

  @doc """
  The description: sanitised HTML (scripts and styles dropped with their
  text) and its plain text, each `nil` when there is none.

      iex> Core.Ingest.Extension.Normalize.description("<p>Go &amp; Elixir</p><script>x()</script>")
      {"<p>Go &amp; Elixir</p>", "Go & Elixir"}
  """
  @spec description(term()) :: {String.t() | nil, String.t() | nil}
  def description(html) when is_binary(html) do
    cleaned =
      html
      |> String.slice(0, 200_000)
      |> String.replace(~r{<(script|style)\b[^>]*>.*?</\1\s*>}is, "")
      |> HtmlSanitizeEx.basic_html()
      |> String.trim()

    text =
      cleaned
      |> String.replace(~r{<br\s*/?>|</(p|div|li|h[1-6]|ul|ol|tr)>}i, "\n")
      |> HtmlSanitizeEx.strip_tags()
      |> entities()
      |> String.replace(~r/[ \t]+/u, " ")
      |> String.replace(~r/\n\s*\n+/u, "\n\n")
      |> String.trim()
      |> String.slice(0, 100_000)

    {blank_nil(cleaned), blank_nil(text)}
  end

  def description(_none), do: {nil, nil}

  defp blank_nil(""), do: nil
  defp blank_nil(text), do: text

  defp entities(text) do
    Enum.reduce(
      [
        {"&nbsp;", " "},
        {"&lt;", "<"},
        {"&gt;", ">"},
        {"&quot;", "\""},
        {"&#39;", "'"},
        {"&amp;", "&"}
      ],
      text,
      fn {entity, char}, acc -> String.replace(acc, entity, char) end
    )
  end

  # ── The snapshot ────────────────────────────────────────────────────────────

  @doc """
  The fields as sent, canonical — keys sorted at every level, without
  `captured_at` — so the same page read twice is the same text, and one
  snapshot (P3's `(job_id, body_sha256)`).
  """
  @spec snapshot_body(map()) :: String.t()
  def snapshot_body(fields),
    do: fields |> Map.delete("captured_at") |> canonical() |> Jason.encode!()

  defp canonical(%{} = map) do
    map
    |> Enum.map(fn {k, v} -> {to_string(k), canonical(v)} end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Jason.OrderedObject.new()
  end

  defp canonical(list) when is_list(list), do: Enum.map(list, &canonical/1)
  defp canonical(value), do: value
end
