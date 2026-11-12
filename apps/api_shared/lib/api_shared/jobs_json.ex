defmodule ApiShared.JobsJSON do
  @moduledoc """
  The job pool's shapes (AQ-03 §7.1): the person, the company ref and card,
  the money, the suggestion, the row, the page, the sheet (AQ-05: with
  `signals`), the check, the signal.
  `Core.Jobs.Sheet` and `Core.Companies` build them; this module lists
  every field by name, so a field somebody adds to the read model never
  reaches the wire unasked. Keys are snake_case and **no map is keyed by
  data**.
  """

  alias ApiShared.LeadsJSON

  @person ~w(user_id name photo_url)a
  @company ~w(id name domain website_url linkedin_url size_band industry hq_country notes_md
              open_jobs created_by inserted_at)a
  @money ~w(min_minor max_minor currency period source is_estimate is_undisclosed text)a
  @row ~w(id title team company source engagement workplace remote_scope onsite_locations money
          posted_on first_seen_at status archived_at best_suggestion)a
  # Every column of `jobs` the sheet adds to the row, by its column name (§7.1).
  @columns ~w(source_url canonical_key source_job_id origin last_seen_at is_reposted poster_name
              description_md description_html seniority category openings allowed_countries
              allowed_regions required_timezones min_overlap_hours overlap_from_time
              overlap_to_time onsite_locations is_relocation_offered visa visa_text duration
              hours_min hours_max start_on is_immediate_start comp_min_minor comp_max_minor
              comp_currency comp_period comp_source comp_text is_comp_undisclosed equity_min_bp
              equity_max_bp equity_kind apply_method apply_url valid_through_on closed_at
              close_reason last_activity_at)a
  @parts ~w(company skills platform_details snapshots merged_from suggestions created_by
            last_changed leads hidden_leads signals can)a
  @signal ~w(observed_at applicant_count is_applicant_count_capped proposals_min proposals_max
             interviewing invites_sent unanswered_invites hires client_last_viewed_at)a
  @can ~w(edit close reopen merge archive unarchive share)a

  @doc "A person, P2's shape: `{user_id, name, photo_url}`, or `nil`."
  def person(nil), do: nil
  def person(p), do: Map.take(p, @person)

  @doc "`GET /companies?q`: `[{id, name, domain}]`."
  def companies(list), do: Enum.map(list, &Map.take(&1, [:id, :name, :domain]))

  @doc "A company's card (`GET /companies/:id`, every company write), or `nil`."
  def company(nil), do: nil

  def company(c) do
    c
    |> Map.take(@company)
    |> Map.update!(:open_jobs, &Enum.map(&1, fn j -> Map.take(j, [:id, :title]) end))
    |> Map.update!(:created_by, &person/1)
  end

  @doc "The list's row."
  def row(r) do
    r
    |> Map.take(@row)
    |> Map.update!(:company, &company_ref/1)
    |> Map.update!(:team, &team_ref/1)
    |> Map.update!(:money, &Map.take(&1, @money))
    |> Map.update!(:best_suggestion, &best/1)
  end

  @doc "`GET /jobs`: `{items, next_cursor}`."
  def page(%{items: items, next_cursor: next}),
    do: %{items: Enum.map(items, &row/1), next_cursor: next}

  @doc "The sheet: the row, every `jobs` column by name, and the parts."
  def sheet(s) do
    s
    |> row()
    |> Map.merge(Map.take(s, @columns))
    |> Map.merge(Map.take(s, @parts))
    |> Map.update!(:company, &company/1)
    |> Map.update!(:skills, &Enum.map(&1, fn k -> Map.take(k, [:id, :name, :is_required]) end))
    |> Map.update!(:snapshots, &Enum.map(&1, fn x -> snapshot(x) end))
    |> Map.update!(:merged_from, &Enum.map(&1, fn m -> merged(m) end))
    |> Map.update!(:suggestions, &Enum.map(&1, fn x -> suggestion(x) end))
    |> Map.update!(:created_by, &person/1)
    |> Map.update!(:last_changed, &last_changed/1)
    |> Map.update!(:leads, &Enum.map(&1, fn l -> LeadsJSON.row(l) end))
    |> Map.update!(:signals, &signals/1)
    |> Map.update!(:can, &Map.take(&1, @can))
  end

  @doc "The job's signals (AQ-05 §11.2): `{latest: signal?, count}`."
  def signals(%{latest: latest, count: count}), do: %{latest: signal(latest), count: count}

  @doc """
  One signals row (AQ-05 §11.3): `{observed_at, applicant_count,
  is_applicant_count_capped, proposals_min, proposals_max, interviewing,
  invites_sent, unanswered_invites, hires, client_last_viewed_at}`, or `nil`.
  """
  def signal(nil), do: nil
  def signal(s), do: Map.take(s, @signal)

  @doc "One profile's suggestion."
  def suggestion(s) do
    %{
      profile: Map.take(s.profile, [:id, :title]),
      customer: Map.take(s.customer, [:id, :display_name]),
      score: s.score,
      parts: Enum.map(s.parts, &Map.take(&1, [:part, :weight, :got, :why])),
      dismissed: dismissed(s.dismissed)
    }
  end

  @doc "`GET /jobs/:id/suggestions`."
  def suggestions(list), do: Enum.map(list, &suggestion/1)

  @doc "`POST /jobs/check`: one of the three states; `in_pool` and `new` carry the lead half (AQ-04A §8.3)."
  def check(%{state: "invalid"} = c), do: Map.take(c, [:state, :reason])

  def check(%{state: "in_pool"} = c) do
    %{
      state: c.state,
      key: c.key,
      source: c.source,
      job: c.job && row(c.job),
      hidden: c.hidden,
      merged_from: c.merged_from && Map.take(c.merged_from, [:title, :at]),
      lead: LeadsJSON.check_half(Map.get(c, :lead))
    }
  end

  def check(%{state: "new"} = c) do
    %{
      state: c.state,
      key: c.key,
      source: c.source,
      similar: Enum.map(c.similar, &row/1),
      lead: LeadsJSON.check_half(Map.get(c, :lead))
    }
  end

  defp team_ref(nil), do: nil
  defp team_ref(t), do: Map.take(t, [:id, :name])

  defp company_ref(nil), do: nil
  defp company_ref(c), do: Map.take(c, [:id, :name])

  defp best(nil), do: nil

  defp best(b) do
    %{
      profile: Map.take(b.profile, [:id, :title]),
      customer: Map.take(b.customer, [:id, :display_name]),
      score: b.score
    }
  end

  defp snapshot(x) do
    x |> Map.take([:id, :captured_at, :origin, :content_type, :by]) |> Map.update!(:by, &person/1)
  end

  defp merged(m),
    do: m |> Map.take([:title, :source_url, :at, :by]) |> Map.update!(:by, &person/1)

  defp dismissed(nil), do: nil
  defp dismissed(d), do: d |> Map.take([:reason, :note, :by, :at]) |> Map.update!(:by, &person/1)

  defp last_changed(nil), do: nil
  defp last_changed(l), do: %{by: person(l.by), at: l.at}
end
