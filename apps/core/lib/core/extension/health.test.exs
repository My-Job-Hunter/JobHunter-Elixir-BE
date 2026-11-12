defmodule Core.Extension.HealthTest do
  @moduledoc """
  AQ-05 §5.2, §11 (P5.5): misses reported, counted per day in the
  organisation's zone, listed for the system admin and nobody else, and
  swept after 30 days — the sweep run twice.
  """

  use Core.CoreCase, async: true

  import Ecto.Query, only: [from: 2]

  alias Core.Extension.{Health, MissSweep}
  alias Data.Extension.Miss

  @now ~U[2026-11-11 09:00:00.000000Z]

  setup do
    c = board_cast_fixture()
    Map.merge(c, %{s_fiza: %{scope_for(c.fiza) | via: :extension}, s_dawud: scope_for(c.dawud)})
  end

  defp miss(attrs \\ %{}) do
    Map.merge(
      %{
        "site" => "linkedin",
        "page_kind" => "job",
        "selector_key" => "salary_text",
        "config_version" => 1,
        "count" => 3
      },
      attrs
    )
  end

  defp report(scope, misses, now \\ @now),
    do: Health.report(scope, %{"extension_version" => "0.1.0", "misses" => misses}, now)

  defp rows(org), do: Repo.all(from(m in Miss, where: m.organisation_id == ^org.id))

  test "a report adds to its day's count; another day is another row", c do
    assert :ok = report(c.s_fiza, [miss(), miss(%{"selector_key" => "page.job.ready"})])
    assert :ok = report(c.s_fiza, [miss(%{"count" => 2})], DateTime.add(@now, 60, :second))

    [ready, salary] = c.org |> rows() |> Enum.sort_by(& &1.selector_key)
    assert {salary.selector_key, salary.count} == {"salary_text", 5}
    assert salary.first_seen_at == @now and salary.last_seen_at == DateTime.add(@now, 60, :second)
    assert {ready.selector_key, ready.count} == {"page.job.ready", 3}

    tomorrow = DateTime.add(@now, 86_400, :second)
    :ok = report(c.s_fiza, [miss()], tomorrow)
    assert length(rows(c.org)) == 3
  end

  test "the day is the organisation's", c do
    {:ok, org} = Data.Organisations.update(c.org, %{timezone: "Asia/Karachi"})
    scope = %{c.s_fiza | organisation: org}

    # 21:00 UTC is 02:00 the next day in Karachi.
    :ok = report(scope, [miss()], ~U[2026-11-11 21:00:00.000000Z])
    assert [%{seen_on: ~D[2026-11-12]}] = rows(c.org)
  end

  test "no address, no page text: a body off the contract is refused whole", c do
    assert {:error, {:invalid, %{"misses" => [why]}}} =
             report(c.s_fiza, [miss(), miss(%{"selector_key" => "https://x.com/jobs"})])

    assert why =~ "item 1"
    assert rows(c.org) == []

    assert {:error, {:invalid, %{"misses" => _}}} = report(c.s_fiza, [miss(%{"count" => 1001})])

    assert {:error, {:invalid, %{"misses" => _}}} =
             report(c.s_fiza, [miss(%{"site" => "indeed"})])

    assert {:error, {:invalid, %{"misses" => _}}} =
             report(c.s_fiza, [miss(%{"page_kind" => "feed"})])

    assert {:error, {:invalid, %{"misses" => _}}} = report(c.s_fiza, List.duplicate(miss(), 201))

    assert Health.report(c.s_fiza, %{"misses" => [miss()]}, @now) ==
             {:error, {:missing, [:extension_version]}}
  end

  test "the page: per site its config, its misses of 7 days and its last capture; every device",
       c do
    config = config_fixture(:linkedin)
    device = device_fixture(c.s_fiza)
    :ok = report(c.s_fiza, [miss()], DateTime.add(@now, -8 * 86_400, :second))
    :ok = report(c.s_fiza, [miss(%{"selector_key" => "title", "count" => 14})])

    assert {:ok, %{sites: [linkedin, upwork], devices: [%{id: id}]}} =
             Health.page(c.s_dawud, @now)

    assert id == device.id

    assert linkedin.site == :linkedin
    assert linkedin.config.version == config.version

    assert [%{selector_key: "title", count: 14, page_kind: :job, extension_version: "0.1.0"}] =
             linkedin.misses

    assert upwork.site == :upwork and upwork.misses == []
  end

  test "the page is the system admin's: 404 for anyone else", c do
    assert Health.page(scope_for(c.hira), @now) == {:error, :not_found}
    assert Health.page(c.s_fiza, @now) == {:error, :not_found}
  end

  test "the sweep forgets misses after 30 days, and a second run deletes nothing", c do
    :ok = report(c.s_fiza, [miss()], DateTime.add(@now, -31 * 86_400, :second))

    :ok =
      report(
        c.s_fiza,
        [miss(%{"selector_key" => "title"})],
        DateTime.add(@now, -29 * 86_400, :second)
      )

    assert Health.sweep(@now) == 1
    assert Health.sweep(@now) == 0
    assert [%{selector_key: "title"}] = rows(c.org)
  end

  test "the worker hands the clock to the sweep, twice over" do
    assert :ok = MissSweep.perform(%Oban.Job{})
    assert :ok = MissSweep.perform(%Oban.Job{})
  end
end
