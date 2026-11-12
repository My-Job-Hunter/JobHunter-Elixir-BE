defmodule ApiShared.ExtensionJSON do
  @moduledoc """
  The extension's shapes (AQ-05 §11.3, pinned before the build): the
  device, the session, the context, the lookup, the capture, `written`,
  the health page and the configs list. `Core.Extension` and
  `Core.Ingest.Extension` build them; this module lists every field by
  name, so nothing reaches the wire unasked. Keys are snake_case and **no
  map is keyed by data**; an optional member (`pick`, `identity.channel`,
  `lookup.lead`, `lead_id`) is `null` when there is none.
  """

  alias ApiShared.JobsJSON
  alias ApiShared.LeadsJSON
  alias ApiShared.MeJSON
  alias Core.Tasks.Person

  @doc """
  A device: `{id, name, extension_version, connected_at, last_seen_at,
  person, current}`. `current` is true for the device whose token made the
  request (on `/ext/v1`), false on `/team/v1`.
  """
  def device(d, current_id \\ nil) do
    %{
      id: d.id,
      name: d.name,
      extension_version: d.extension_version,
      connected_at: d.connected_at,
      last_seen_at: d.last_seen_at,
      person: d.user |> Person.view() |> JobsJSON.person(),
      current: not is_nil(current_id) and d.id == current_id
    }
  end

  @doc "`POST /ext/v1/session`: `{access_token, refresh_token, device, me}`."
  def session(%{tokens: tokens, device: device, me: me}) do
    %{
      access_token: tokens.access_token,
      refresh_token: tokens.refresh_token,
      device: device(device, device.id),
      me: MeJSON.me(%{me: me})
    }
  end

  @doc """
  `GET /ext/v1/context`: `{me: {person, is_admin}, identity: {state,
  channel}, profiles: [{id, title, customer, teams, cvs, matched}], pick}`.
  """
  def context(c) do
    %{
      me: %{person: JobsJSON.person(c.me.person), is_admin: c.me.is_admin},
      identity: %{state: c.identity.state, channel: channel(c.identity.channel)},
      profiles:
        Enum.map(c.profiles, fn p ->
          %{
            id: p.id,
            title: p.title,
            customer: Map.take(p.customer, [:id, :display_name]),
            teams: Enum.map(p.teams, &Map.take(&1, [:id, :name])),
            cvs: Enum.map(p.cvs, &Map.take(&1, [:id, :label, :version, :is_default])),
            matched: p.matched
          }
        end),
      pick: c.pick && Map.take(c.pick, [:profile_id, :team_id])
    }
  end

  defp channel(nil), do: nil

  defp channel(ch) do
    %{
      id: ch.id,
      kind: ch.kind,
      label: ch.label,
      operated_by: ch.operated_by,
      customer: %{id: ch.customer.id, display_name: ch.customer.display_name}
    }
  end

  @doc """
  `GET /ext/v1/jobs/lookup`: `{key, source, check, lead, banner: {tone,
  words}, can: {save, apply, apply_again}, lead_id}` — `check` P3's (with
  its lead half), `lead` the lead half again (`null` without a profile).
  """
  def lookup(l) do
    %{
      key: l.key,
      source: l.source,
      check: JobsJSON.check(l.check),
      lead: LeadsJSON.check_half(l.lead),
      banner: Map.take(l.banner, [:tone, :words]),
      can: Map.take(l.can, [:save, :apply, :apply_again]),
      lead_id: l.lead_id
    }
  end

  @doc """
  `POST /ext/v1/jobs/capture`: `{state: "not_in_pool" | "hidden"}`, or
  `{state: "refreshed", job: P3's row, filled: [field], signals: {latest,
  count}, unmatched_skills: [string]}`.
  """
  def capture(%{state: "refreshed"} = c) do
    %{
      state: c.state,
      job: JobsJSON.row(c.job),
      filled: c.filled,
      signals: JobsJSON.signals(c.signals),
      unmatched_skills: c.unmatched_skills
    }
  end

  def capture(c), do: %{state: c.state}

  @doc "`written`: `{answer, lead: P4a's card, job: P3's row, unmatched_skills, link_path}`."
  def written(w) do
    %{
      answer: w.answer,
      lead: LeadsJSON.card(w.lead),
      job: JobsJSON.row(w.job),
      unmatched_skills: w.unmatched_skills,
      link_path: w.link_path
    }
  end

  @doc """
  `GET /team/v1/extension/health`: `{sites: [{site, config: {version,
  published_at}, misses: [miss], last_capture_at}], devices: [device]}`.
  """
  def health(h) do
    %{
      sites:
        Enum.map(h.sites, fn s ->
          %{
            site: s.site,
            config: s.config && Map.take(s.config, [:version, :published_at]),
            misses:
              Enum.map(
                s.misses,
                &Map.take(&1, [
                  :selector_key,
                  :page_kind,
                  :config_version,
                  :extension_version,
                  :count,
                  :first_seen_at,
                  :last_seen_at
                ])
              ),
            last_capture_at: s.last_capture_at
          }
        end),
      devices: Enum.map(h.devices, &device/1)
    }
  end

  @doc "`GET /team/v1/extension/configs`: `[{site, version, sha256, published_at}]`."
  def configs(list), do: Enum.map(list, &Map.take(&1, [:site, :version, :sha256, :published_at]))
end
