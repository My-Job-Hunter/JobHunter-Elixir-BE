defmodule Utils.JobKey do
  @moduledoc """
  A job link to its **canonical key** (AQ-03 §6.1), pure: two links to one
  posting give one key, so the pool holds one row per posting (the unique
  `(organisation_id, canonical_key)` of `jobs`).

  A link is trimmed and given `https://` when it has no scheme; its host is
  lowercased and loses `www.`; the fragment goes. Then the first rule that
  matches wins:

  | Source | Key |
  |---|---|
  | `linkedin` | `linkedin:{id}` from `/jobs/view/{id}`, `/jobs/view/{slug}-{id}` or `currentJobId` |
  | `upwork` | `upwork:{~0id}`, lowercased; a slide-over's `/details/~0id` too |
  | `indeed` | `indeed:{jk}` from `jk` or `vjk` |
  | `yc_waas` | `yc:{id}` |
  | `wellfound` | `wellfound:{id}` |
  | `greenhouse` | `greenhouse:{board}/{id}`, either board host, any suffix, or the embed form |
  | `lever` · `ashby` · `workable` | `{source}:{company}/{id}`, `/apply` and `/application` dropped |
  | `company_site` | host + path without the trailing `/` + the kept query, sorted |

  A known board's link without a job id is `{:error, :not_a_job}`; anything
  without a dotted host, or not `http(s)`, is `{:error, :not_a_link}`.
  Board and company segments are lowercased; ids keep their case except
  Upwork's. `Utils.JobKeyTest` holds every vector of §6.2.

  `similar_title?/2` is the prototype's similar-posting rule (§6.3).
  """

  @dropped_params ~w(ref refid referrer trackingid trk src source gh_src lever-origin lever-source
                     fbclid gclid li_fat_id mc_cid mc_eid _hsenc _hsmi)

  @type source ::
          :linkedin
          | :upwork
          | :indeed
          | :yc_waas
          | :wellfound
          | :greenhouse
          | :lever
          | :ashby
          | :workable
          | :company_site
  @type parsed :: %{key: String.t(), source: source(), source_job_id: String.t() | nil}

  @doc """
  The key of a job link.

      iex> Utils.JobKey.parse("https://www.linkedin.com/jobs/view/4012233871")
      {:ok, %{key: "linkedin:4012233871", source: :linkedin, source_job_id: "4012233871"}}
      iex> Utils.JobKey.parse("https://www.linkedin.com/in/someone")
      {:error, :not_a_job}
      iex> Utils.JobKey.parse("not a link")
      {:error, :not_a_link}
  """
  @spec parse(term()) :: {:ok, parsed()} | {:error, :not_a_link | :not_a_job}
  def parse(link) when is_binary(link) do
    with {:ok, uri} <- to_uri(String.trim(link)) do
      host = uri.host |> String.downcase() |> strip_www()
      path = uri.path || ""
      query = if uri.query, do: uri.query |> URI.query_decoder() |> Enum.to_list(), else: []
      rule(host, path, query)
    end
  end

  def parse(_link), do: {:error, :not_a_link}

  @doc """
  The prototype's similar-title rule: lowercased, everything but letters and
  digits turned to spaces, split into words; similar when the shared words
  are at least 60% of the longer title's.

      iex> Utils.JobKey.similar_title?("Staff Engineer (remote work)", "Staff engineer, remote work")
      true
      iex> Utils.JobKey.similar_title?("Backend Developer", "Product Designer")
      false
  """
  @spec similar_title?(String.t() | nil, String.t() | nil) :: boolean()
  def similar_title?(a, b) when is_binary(a) and is_binary(b) do
    words_a = words(a)
    words_b = words(b)
    longer = max(length(words_a), length(words_b))

    if longer == 0 do
      false
    else
      set_b = MapSet.new(words_b)
      shared = Enum.count(words_a, &MapSet.member?(set_b, &1))
      shared / longer >= 0.6
    end
  end

  def similar_title?(_a, _b), do: false

  defp words(title) do
    title
    |> String.downcase()
    |> String.replace(~r/[^\p{L}\p{N}]+/u, " ")
    |> String.split()
  end

  # ── The link ────────────────────────────────────────────────────────────────

  defp to_uri(""), do: {:error, :not_a_link}

  # A scheme without `//` (`mailto:`, `javascript:`) is no web link at all;
  # `host:port` is.
  defp to_uri(link) do
    if link =~ ~r{^[a-zA-Z][a-zA-Z0-9+.-]*:(?!//|\d)},
      do: {:error, :not_a_link},
      else: web_uri(link)
  end

  defp web_uri(link) do
    link = if link =~ ~r{^[a-zA-Z][a-zA-Z0-9+.-]*://}, do: link, else: "https://" <> link

    case URI.new(link) do
      {:ok, %URI{scheme: scheme, host: host} = uri} when is_binary(host) ->
        if String.downcase(scheme || "") in ["http", "https"] and dotted?(host),
          do: {:ok, uri},
          else: {:error, :not_a_link}

      _unparseable ->
        {:error, :not_a_link}
    end
  end

  defp dotted?(host) do
    parts = String.split(host, ".")
    length(parts) >= 2 and Enum.all?(parts, &(&1 != ""))
  end

  defp strip_www("www." <> rest), do: rest
  defp strip_www(host), do: host

  # ── The rules, in order ─────────────────────────────────────────────────────

  # The boards matched by domain, any subdomain; then the exact hosts.
  defp rule(host, path, query) do
    cond do
      on?(host, "linkedin.com") -> linkedin(path, query)
      on?(host, "upwork.com") -> upwork(path)
      on?(host, "indeed.com") -> indeed(query)
      true -> exact_host(host, path, query)
    end
  end

  defp exact_host(host, path, _query) when host in ["workatastartup.com", "ycombinator.com"],
    do: yc(host, path)

  defp exact_host(host, path, _query) when host in ["wellfound.com", "angel.co"],
    do: wellfound(path)

  defp exact_host(host, path, query)
       when host in ["boards.greenhouse.io", "job-boards.greenhouse.io"],
       do: greenhouse(path, query)

  defp exact_host("jobs.lever.co", path, _query), do: two_part(:lever, path, ["apply"])
  defp exact_host("jobs.ashbyhq.com", path, _query), do: two_part(:ashby, path, ["application"])
  defp exact_host("apply.workable.com", path, _query), do: workable(path)
  defp exact_host(host, path, query), do: company_site(host, path, query)

  defp on?(host, domain), do: host == domain or String.ends_with?(host, "." <> domain)

  defp linkedin(path, query) do
    viewed = Regex.run(~r{^/jobs/view/(?:[^/]*-)?(\d+)(?:/.*)?$}, path)
    current = param(query, "currentJobId")

    cond do
      viewed -> found(:linkedin, "linkedin:", List.last(viewed))
      jobs_page_with?(path, current) -> found(:linkedin, "linkedin:", current)
      true -> {:error, :not_a_job}
    end
  end

  defp jobs_page_with?(path, current),
    do: String.starts_with?(path, "/jobs") and is_binary(current) and current =~ ~r/^\d+$/

  defp upwork(path) do
    # AQ-05: the job-details slide-overs (`/nx/search/jobs/details/~0…`,
    # `/nx/find-work/best-matches/details/~0…`) name the id right after
    # their `/details/` segment.
    job_page? =
      String.starts_with?(path, "/jobs/") or String.starts_with?(path, "/freelance-jobs/apply/") or
        path =~ ~r{^/nx/.*/job/} or path =~ ~r{/details/~0[0-9A-Za-z]+}

    case job_page? && Regex.run(~r/~0[0-9A-Za-z]+/, path) do
      [id] -> found(:upwork, "upwork:", String.downcase(id))
      _none -> {:error, :not_a_job}
    end
  end

  defp indeed(query) do
    case Utils.presence(param(query, "jk")) || Utils.presence(param(query, "vjk")) do
      nil -> {:error, :not_a_job}
      jk -> found(:indeed, "indeed:", jk)
    end
  end

  defp yc("workatastartup.com", path) do
    case segments(path) do
      ["jobs", id | _rest] -> found(:yc_waas, "yc:", id)
      _other -> {:error, :not_a_job}
    end
  end

  defp yc("ycombinator.com", path) do
    case segments(path) do
      ["companies", _slug, "jobs", id | _rest] -> found(:yc_waas, "yc:", leading_id(id))
      _other -> {:error, :not_a_job}
    end
  end

  defp wellfound(path) do
    case segments(path) do
      ["jobs", id | _rest] -> wellfound_id(id)
      ["company", _slug, "jobs", id | _rest] -> wellfound_id(id)
      _other -> {:error, :not_a_job}
    end
  end

  defp wellfound_id(segment) do
    case Regex.run(~r/^(\d+)/, segment) do
      [_whole, id] -> found(:wellfound, "wellfound:", id)
      nil -> {:error, :not_a_job}
    end
  end

  defp greenhouse(path, query) do
    case segments(path) do
      ["embed", "job_app" | _rest] ->
        board = Utils.presence(param(query, "for"))
        token = Utils.presence(param(query, "token"))

        if board && token,
          do: found(:greenhouse, "greenhouse:#{String.downcase(board)}/", token),
          else: {:error, :not_a_job}

      [board, "jobs", id | _rest] ->
        found(:greenhouse, "greenhouse:#{String.downcase(board)}/", id)

      _other ->
        {:error, :not_a_job}
    end
  end

  defp two_part(source, path, dropped) do
    case segments(path) -- dropped do
      [company, id] -> found(source, "#{source}:#{String.downcase(company)}/", id)
      _other -> {:error, :not_a_job}
    end
  end

  defp workable(path) do
    case segments(path) do
      [company, "j", code | _rest] ->
        found(:workable, "workable:#{String.downcase(company)}/", code)

      _other ->
        {:error, :not_a_job}
    end
  end

  defp company_site(host, path, query) do
    kept =
      query
      |> Enum.reject(fn {name, _value} -> dropped?(String.downcase(name)) end)
      |> Enum.sort()

    path = String.trim_trailing(path, "/")
    key = if kept == [], do: host <> path, else: host <> path <> "?" <> URI.encode_query(kept)

    {:ok, %{key: key, source: :company_site, source_job_id: nil}}
  end

  defp dropped?("utm_" <> _rest), do: true
  defp dropped?(name), do: name in @dropped_params

  defp found(source, prefix, id),
    do: {:ok, %{key: prefix <> id, source: source, source_job_id: id}}

  defp segments(path), do: String.split(path, "/", trim: true)

  defp leading_id(segment), do: segment |> String.split("-", parts: 2) |> hd()

  defp param(query, name) do
    Enum.find_value(query, fn
      {^name, value} -> value
      _other -> nil
    end)
  end
end
