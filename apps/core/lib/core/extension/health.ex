defmodule Core.Extension.Health do
  @moduledoc """
  The selectors' health (AQ-05 §5.2, §11, QP5-22): the misses a device
  reports (`POST /ext/v1/health`), counted per day — the organisation's —
  per site, selector, config version and extension version; the page the
  system admin reads (`GET /team/v1/extension/health`, the last 7 days);
  and the hourly sweep that forgets them after 30 days. No address and no
  page text is ever taken.
  """

  alias Core.Access
  alias Core.Tasks
  alias Data.Devices
  alias Data.Extension, as: Store
  alias Data.Repo
  alias Data.Scope
  alias Data.Vocabulary

  @max_items 200
  @max_count 1000
  @shown_days 7
  @kept_days 30

  @doc "How long a miss is kept: 30 days."
  def kept_days, do: @kept_days

  @doc """
  `POST /ext/v1/health {extension_version, misses: [{site, page_kind,
  selector_key, config_version, count}]}`: at most 200 items, each `count`
  1…1000, all or nothing. Each adds to its day's row in the organisation's
  zone. Answers `:ok`; a body off the contract is a field error naming the
  item.
  """
  @spec report(Scope.t(), map(), DateTime.t()) :: :ok | {:error, term()}
  def report(%Scope{} = scope, params, %DateTime{} = now) do
    with :ok <- Access.why_not(scope, :report_misses, :extension),
         {:ok, version} <- extension_version(params["extension_version"]),
         {:ok, items} <- items(params["misses"]),
         rows = rows(scope, version, items, now),
         {:ok, _n} <- Repo.transaction(fn -> ok!(Store.add_misses(rows)) end) do
      :ok
    end
  end

  # Each item on its day's row: the organisation, the extension's version,
  # the day in the organisation's zone.
  defp rows(scope, version, items, now) do
    day = %{
      organisation_id: Scope.organisation_id(scope),
      extension_version: version,
      seen_on: scope |> Tasks.zone() |> today(now),
      first_seen_at: now,
      last_seen_at: now
    }

    Enum.map(items, &Map.merge(&1, day))
  end

  defp ok!({:ok, n}), do: n
  defp ok!({:error, reason}), do: Repo.rollback(reason)

  defp extension_version(version) when is_binary(version) do
    case String.trim(version) do
      "" -> {:error, {:missing, [:extension_version]}}
      v when byte_size(v) > 20 -> invalid("extension_version", "is too long")
      v -> {:ok, v}
    end
  end

  defp extension_version(nil), do: {:error, {:missing, [:extension_version]}}
  defp extension_version(_other), do: invalid("extension_version", "is not a string")

  defp items(list) when is_list(list) and length(list) > @max_items,
    do: invalid("misses", "has more than #{@max_items} items")

  defp items(list) when is_list(list) do
    list
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {item, i}, {:ok, acc} ->
      case item(item) do
        {:ok, row} -> {:cont, {:ok, [row | acc]}}
        {:error, why} -> {:halt, invalid("misses", "item #{i}: #{why}")}
      end
    end)
    |> case do
      {:ok, rows} -> {:ok, Enum.reverse(rows)}
      error -> error
    end
  end

  defp items(nil), do: {:error, {:missing, [:misses]}}
  defp items(_other), do: invalid("misses", "is a list")

  defp item(%{} = item) do
    with {:ok, site} <- member(item["site"], Vocabulary.ext_sites(), "site"),
         {:ok, kind} <- member(item["page_kind"], Vocabulary.ext_page_kinds(), "page_kind"),
         {:ok, key} <- selector_key(item["selector_key"]),
         {:ok, config} <- integer(item["config_version"], 0..1_000_000, "config_version"),
         {:ok, count} <- integer(item["count"], 1..@max_count, "count") do
      {:ok,
       %{site: site, page_kind: kind, selector_key: key, config_version: config, count: count}}
    end
  end

  defp item(_other), do: {:error, "is not an object"}

  defp member(value, allowed, field) do
    if is_binary(value) and value in allowed,
      do: {:ok, String.to_atom(value)},
      else: {:error, "#{field} is one of #{Enum.join(allowed, ", ")}"}
  end

  defp selector_key(key) when is_binary(key) do
    if key =~ ~r/^[a-z][a-z0-9_.]{0,59}$/,
      do: {:ok, key},
      else: {:error, "selector_key is a field key, identity, confirmation or page.<kind>.ready"}
  end

  defp selector_key(_key), do: {:error, "selector_key is missing"}

  defp integer(value, first..last//_step, field) do
    if is_integer(value) and value >= first and value <= last,
      do: {:ok, value},
      else: {:error, "#{field} is a whole number from #{first} to #{last}"}
  end

  defp invalid(field, message), do: {:error, {:invalid, %{field => [message]}}}

  # ── The page ────────────────────────────────────────────────────────────────

  @doc """
  `GET /team/v1/extension/health`, the system admin's (404 for anyone
  else): per site its live config, its misses of the last 7 days (summed
  over the days) and its last capture; and every live device of the
  organisation. `%{sites: [%{site, config, misses, last_capture_at}],
  devices}`.
  """
  @spec page(Scope.t(), DateTime.t()) :: {:ok, map()} | {:error, term()}
  def page(%Scope{} = scope, %DateTime{} = now) do
    with :ok <- Access.why_not(scope, :read_health, :extension) do
      org_id = Scope.organisation_id(scope)
      since_on = scope |> Tasks.zone() |> today(now) |> Date.add(-(@shown_days - 1))
      misses = Enum.group_by(Store.misses_since(org_id, since_on), & &1.site)

      sites =
        for site <- Vocabulary.ext_sites() do
          site = String.to_atom(site)

          %{
            site: site,
            config: Store.live_config(site),
            misses: Map.get(misses, site, []),
            last_capture_at: Store.last_capture_at(org_id, site)
          }
        end

      {:ok, %{sites: sites, devices: Devices.list(org_id)}}
    end
  end

  # ── The sweep ───────────────────────────────────────────────────────────────

  @doc """
  Forgets every organisation's misses last seen more than 30 days before
  `now` (`Core.Extension.MissSweep`, hourly). Idempotent: a second run
  deletes nothing. Answers how many went.
  """
  @spec sweep(DateTime.t()) :: non_neg_integer()
  def sweep(%DateTime{} = now),
    do: Store.delete_misses_for_system(DateTime.add(now, -@kept_days * 86_400, :second))

  defp today(zone, now) do
    case DateTime.shift_zone(now, zone) do
      {:ok, local} -> DateTime.to_date(local)
      {:error, _unknown} -> DateTime.to_date(now)
    end
  end
end
