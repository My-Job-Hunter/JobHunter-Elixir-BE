defmodule Core.Extension.Configs do
  @moduledoc """
  The selector documents (AQ-05 §6.4, §11.4, QP5-21): each site's JSON in
  `apps/core/priv/extension/<site>.json`, **validated against contract 1**
  (`validate/1`), published as versions into `extension_configs` — v1 by the
  reference seed, a new version by `mix aq.ext_config` whenever a file's
  hash changed — and served live with its hash as the `ETag`.

  Contract 1, as pinned:

      {site, contract: 1,
       pages:        {<page_kind>: {url: [substring | "re:<regex>"], ready: [css]}},
       fields:       {<field key>: {on: <page_kind>, css: [css] (1–6),
                      read: "text" | "href" | "html" | "present" | "attr:<name>",
                      required: bool, all?: bool}},
       identity:     {css: [css], read: "href"},
       confirmation: {on: <page_kind>, css: [css], read: "present"}?,
       apply:        {on: "job", easy_css?: [css], external_css?: [css]}?}

  A field key is a member of §11.3's `fields`, dotted for nesting
  (`title`, `upwork.proposals_text`, `upwork.client.rating_text`) — AQ-06
  §11.6 adds the `thread` page's (`other_profile_url`, `other_name`,
  `messages` and each message's `external_id`, `side`, `sent_text`,
  `text`); a page kind is `ext_page_kinds`'s, and every `on` names a page
  of the document.
  """

  alias Core.Access
  alias Data.Extension, as: Store
  alias Data.Scope
  alias Data.Vocabulary

  @field_keys ~w(title company_name company_url location_text workplace_text employment_text
                 seniority_text salary_text posted_text applicants_text apply_kind apply_url
                 skills_text description_html is_promoted hiring_team_text bid_text
                 connects_spent_text
                 upwork.budget_text upwork.rate_text upwork.experience_text upwork.duration_text
                 upwork.hours_text upwork.connects_text upwork.proposals_text
                 upwork.last_viewed_text upwork.interviewing_text upwork.invites_text
                 upwork.unanswered_text upwork.hires_text
                 upwork.client.payment_verified upwork.client.rating_text
                 upwork.client.reviews_text upwork.client.location_text
                 upwork.client.local_time_text upwork.client.jobs_posted_text
                 upwork.client.hire_rate_text upwork.client.open_jobs_text
                 upwork.client.spent_text upwork.client.hires_text
                 upwork.client.active_hires_text upwork.client.avg_rate_text
                 upwork.client.member_since_text
                 other_profile_url other_name messages messages.external_id messages.side
                 messages.sent_text messages.text)
  @top ~w(site contract pages fields identity confirmation apply)
  @sites Vocabulary.ext_sites() |> Enum.map(&String.to_atom/1)
  @reads ~w(text href html present)

  @doc "The field keys a document may read (§11.4)."
  def field_keys, do: @field_keys

  @doc "Where the repo's documents are: `core`'s `priv/extension`."
  @spec dir() :: Path.t()
  def dir, do: Application.app_dir(:core, "priv/extension")

  # ── The contract ────────────────────────────────────────────────────────────

  @doc """
  Whether a decoded document keeps contract 1: `:ok`, or `{:error,
  problems}`, each a path and what is wrong with it. Pure.

      iex> Core.Extension.Configs.validate(%{"site" => "upwork"})
      {:error, ["contract: is not 1", "pages: is missing", "fields: is missing", "identity: is missing"]}
  """
  @spec validate(term()) :: :ok | {:error, [String.t()]}
  def validate(%{} = doc) do
    pages = if is_map(doc["pages"]), do: Map.keys(doc["pages"]), else: []

    problems =
      List.flatten([
        unknown(doc, @top, ""),
        site(doc["site"]),
        if(doc["contract"] == 1, do: [], else: ["contract: is not 1"]),
        required(doc, "pages", &pages/1),
        required(doc, "fields", &fields(&1, pages)),
        required(doc, "identity", &identity/1),
        optional(doc, "confirmation", &confirmation(&1, pages)),
        optional(doc, "apply", &apply_rule(&1, pages))
      ])

    if problems == [], do: :ok, else: {:error, problems}
  end

  def validate(_doc), do: {:error, ["the document is not a JSON object"]}

  @doc """
  A file's text for `site`, decoded and validated, and naming that site:
  `:ok` or `{:error, problems}`.
  """
  @spec check(String.t(), String.t()) :: :ok | {:error, [String.t()]}
  def check(site, body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{"site" => ^site} = doc} -> validate(doc)
      {:ok, %{} = doc} -> with :ok <- validate(doc), do: {:error, ["site: is not #{site}"]}
      {:ok, _other} -> {:error, ["the document is not a JSON object"]}
      {:error, error} -> {:error, ["not JSON: " <> Exception.message(error)]}
    end
  end

  defp site(site) do
    if site in Vocabulary.ext_sites(),
      do: [],
      else: ["site: is not one of #{Enum.join(Vocabulary.ext_sites(), ", ")}"]
  end

  defp required(doc, key, check) do
    case Map.fetch(doc, key) do
      {:ok, %{} = value} -> prefix(key, check.(value))
      {:ok, _other} -> ["#{key}: is not an object"]
      :error -> ["#{key}: is missing"]
    end
  end

  defp optional(doc, key, check) do
    case Map.fetch(doc, key) do
      :error -> []
      {:ok, nil} -> []
      {:ok, %{} = value} -> prefix(key, check.(value))
      {:ok, _other} -> ["#{key}: is not an object"]
    end
  end

  defp prefix(key, problems) do
    Enum.map(List.flatten(problems), fn
      ":" <> _rest = problem -> key <> problem
      problem -> "#{key}.#{problem}"
    end)
  end

  defp pages(pages) when pages == %{}, do: [": has no page"]
  defp pages(pages), do: Enum.map(pages, fn {kind, page} -> page(kind, page) end)

  defp page(kind, page) do
    cond do
      kind not in Vocabulary.ext_page_kinds() ->
        "#{kind}: is not a page kind"

      not is_map(page) ->
        "#{kind}: is not an object"

      true ->
        [
          unknown(page, ~w(url ready), kind <> "."),
          list(page["url"], "#{kind}.url", &url_rule/1, 1..20),
          css(page["ready"], "#{kind}.ready")
        ]
    end
  end

  defp fields(fields, _pages) when fields == %{}, do: [": has no field"]

  defp fields(fields, pages),
    do: Enum.map(fields, fn {key, field} -> field(key, field, pages) end)

  defp field(key, _field, _pages) when key not in @field_keys,
    do: "#{key}: is not a field of §11.3"

  defp field(key, field, _pages) when not is_map(field), do: "#{key}: is not an object"

  defp field(key, field, pages) do
    [
      unknown(field, ~w(on css read required all), key <> "."),
      on(field["on"], key, pages),
      css(field["css"], key <> ".css", 1..6),
      read(field["read"], key),
      if(is_boolean(field["required"]), do: [], else: ["#{key}.required: is not true or false"]),
      if(field["all"] in [nil, true, false], do: [], else: ["#{key}.all: is not true or false"])
    ]
  end

  defp identity(identity) do
    [
      unknown(identity, ~w(css read), ""),
      css(identity["css"], "css"),
      if(identity["read"] == "href", do: [], else: ["read: is not href"])
    ]
  end

  defp confirmation(c, pages) do
    [
      unknown(c, ~w(on css read), ""),
      on(c["on"], "on", pages, :bare),
      css(c["css"], "css"),
      if(c["read"] == "present", do: [], else: ["read: is not present"])
    ]
  end

  defp apply_rule(a, pages) do
    [
      unknown(a, ~w(on easy_css external_css), ""),
      if(a["on"] == "job", do: on("job", "on", pages, :bare), else: ["on: is not job"]),
      if(Map.has_key?(a, "easy_css"), do: css(a["easy_css"], "easy_css"), else: []),
      if(Map.has_key?(a, "external_css"), do: css(a["external_css"], "external_css"), else: [])
    ]
  end

  defp on(kind, where, pages, style \\ :field) do
    path = if style == :bare, do: where, else: where <> ".on"

    cond do
      not is_binary(kind) -> ["#{path}: is missing"]
      kind not in Vocabulary.ext_page_kinds() -> ["#{path}: is not a page kind"]
      kind not in pages -> ["#{path}: names no page of this document"]
      true -> []
    end
  end

  defp read("attr:" <> name, key) do
    if name =~ ~r/^[a-z][a-z0-9_:-]*$/, do: [], else: ["#{key}.read: is not attr:<name>"]
  end

  defp read(read, key) do
    if read in @reads,
      do: [],
      else: ["#{key}.read: is not text, href, html, present or attr:<name>"]
  end

  defp css(selectors, path, count \\ 1..20), do: list(selectors, path, &selector/1, count)

  defp list(values, path, check, first..last//_step) when is_list(values) do
    n = length(values)

    if n < first or n > last,
      do: ["#{path}: has #{n}, not #{first}–#{last}"],
      else: values |> Enum.with_index() |> Enum.flat_map(&item(&1, path, check))
  end

  defp list(_values, path, _check, _count), do: ["#{path}: is not a list"]

  defp item({value, i}, path, check) do
    case check.(value) do
      :ok -> []
      {:error, why} -> ["#{path}[#{i}]: #{why}"]
    end
  end

  defp selector(css) when is_binary(css) do
    cond do
      String.trim(css) == "" -> {:error, "is blank"}
      String.length(css) > 300 -> {:error, "is over 300 characters"}
      true -> :ok
    end
  end

  defp selector(_css), do: {:error, "is not a string"}

  defp url_rule("re:" <> source) do
    case Regex.compile(source) do
      {:ok, _regex} -> :ok
      {:error, _why} -> {:error, "is not a regular expression"}
    end
  end

  defp url_rule(text) when is_binary(text) do
    if String.trim(text) == "", do: {:error, "is blank"}, else: :ok
  end

  defp url_rule(_other), do: {:error, "is not a string"}

  defp unknown(map, known, path) do
    for key <- Map.keys(map), key not in known, do: "#{path}#{key}: is not in contract 1"
  end

  # ── Published versions ──────────────────────────────────────────────────────

  @doc """
  `GET /ext/v1/config?site`: the live document of `site`, `%{site, version,
  body, sha256, published_at}`. A site off `ext_sites` is a field error;
  one with nothing published, not found.
  """
  @spec live(Scope.t(), term()) :: {:ok, map()} | {:error, term()}
  def live(%Scope{} = scope, site) do
    with :ok <- Access.why_not(scope, :use, :extension),
         {:ok, site} <- site_param(site) do
      case Store.live_config(site) do
        nil -> {:error, :not_found}
        config -> {:ok, config}
      end
    end
  end

  @doc """
  `GET /team/v1/extension/configs?site`: every published version, newest
  first — `site` narrows — for the system admin (404 for anyone else).
  """
  @spec list(Scope.t(), map()) :: {:ok, [map()]} | {:error, term()}
  def list(%Scope{} = scope, params) do
    with :ok <- Access.why_not(scope, :read_configs, :extension),
         {:ok, site} <- optional_site(Utils.presence(to_string(params["site"] || ""))),
         do: {:ok, Store.configs(site)}
  end

  defp optional_site(nil), do: {:ok, nil}
  defp optional_site(site), do: site_param(site)

  defp site_param(site) do
    if is_binary(site) and site in Vocabulary.ext_sites(),
      do: {:ok, Enum.find(@sites, &(Atom.to_string(&1) == site))},
      else:
        {:error,
         {:invalid, %{"site" => ["is one of #{Enum.join(Vocabulary.ext_sites(), ", ")}"]}}}
  end

  @doc """
  `mix aq.ext_config`: each site's file in `dir`, validated, published as a
  new version when its text is not the live one's. Answers one line per
  site: `{site, {:published, version}}`, `{site, {:unchanged, version}}`,
  `{site, :missing}`, or `{site, {:invalid, problems}}` (nothing published
  for that site). The system acting: no person, `via: system`.
  """
  @spec publish_files(Scope.t(), Path.t(), DateTime.t()) :: [{String.t(), term()}]
  def publish_files(%Scope{} = scope, dir, %DateTime{} = now) do
    :ok = Access.why_not(scope, :read_configs, :extension)

    for site <- Vocabulary.ext_sites() do
      path = Path.join(dir, site <> ".json")

      with {:ok, body} <- File.read(path),
           :ok <- check(site, body) do
        {site, publish(site, body, now)}
      else
        {:error, :enoent} -> {site, :missing}
        {:error, problems} when is_list(problems) -> {site, {:invalid, problems}}
        {:error, reason} -> {site, {:invalid, [inspect(reason)]}}
      end
    end
  end

  defp publish(site, body, now) do
    case Store.publish(site, body, now) do
      {:ok, {:published, config}} -> {:published, config.version}
      {:ok, {:unchanged, config}} -> {:unchanged, config.version}
      {:error, {:published_before, version}} -> {:published_before, version}
      {:error, changeset} -> {:invalid, [inspect(changeset.errors)]}
    end
  end
end
