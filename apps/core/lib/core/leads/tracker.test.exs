defmodule Core.Leads.TrackerTest do
  @moduledoc """
  AQ-04B §8.1, §8.4, QP4b-15, QP4b-18: the Tracker — one team's leads by
  `peer_leads`, the board's filters plus `state`, `label` and `missing`;
  `sort`/`dir` on any column, `group` with counts, keyset pages of 50 with
  the total — and its CSV (a BOM, every column, money as written,
  audited).
  """

  use Core.CoreCase, async: true

  alias Core.Leads.Tracker

  @now ~U[2026-11-11 09:00:00.000000Z]

  setup do
    c = board_cast_fixture()
    fiza = scope_for(c.fiza)
    bamboo = company_fixture(c.org, name: "Bamboo Invest")

    paid =
      job_fixture(fiza,
        team: c.backend,
        title: "Backend Developer",
        company: bamboo,
        comp_min_minor: 30_000_000,
        comp_max_minor: 40_000_000,
        comp_currency: "PKR",
        comp_period: :month
      )

    cv = document_fixture(c.golang, label: "Golang CV")
    naveed = profile_fixture(c.naveed, title: "Golang")

    applied =
      lead_fixture(fiza,
        job: paid,
        profile: c.golang,
        as: :apply,
        document_id: cv.id,
        last_activity_at: ~U[2026-11-10 09:00:00.000000Z]
      )

    saved =
      lead_fixture(scope_for(c.qasim),
        job: job_fixture(fiza, team: c.backend, title: "Another role"),
        profile: naveed,
        last_activity_at: ~U[2026-11-09 09:00:00.000000Z]
      )

    done =
      lead_fixture(fiza,
        job: job_fixture(fiza, team: c.backend, title: "Closed role"),
        profile: c.golang,
        state: :done,
        last_activity_at: ~U[2026-11-08 09:00:00.000000Z]
      )

    _elsewhere = lead_fixture(scope_for(c.hira), team: c.frontend)
    label = label_fixture(fiza, c.backend, name: "Priority client")
    Data.Labels.put_for_lead(applied.id, [label.id])

    Map.merge(c, %{applied: applied, saved: saved, done: done, label: label, cv: cv})
  end

  defp page(c, who, params \\ %{}),
    do: Tracker.page(scope_for(who), Map.put(params, "team_id", c.backend.id), @now)

  defp ids({:ok, %{items: items}}), do: Enum.map(items, & &1.id)

  test "every lead of the team, newest activity first, with the total and the row's shape", c do
    assert {:ok, %{items: [row | _] = items, total: 3, next_cursor: nil, groups: nil}} =
             page(c, c.hira)

    assert Enum.map(items, & &1.id) == [c.applied.id, c.saved.id, c.done.id]
    assert row.title == "Backend Developer" and row.company.name == "Bamboo Invest"
    assert row.labels == [%{id: c.label.id, name: "Priority client"}]
    assert row.cv == %{id: c.cv.id, label: "Golang CV", version: 1}
    assert row.missing == []
    assert row.money.currency == "PKR"
    assert %{archives_on: _, warn: false} = row.quiet
    assert row.owner.name == "Fiza"

    saved = Enum.find(items, &(&1.id == c.saved.id))
    assert saved.missing == ["money", "cv"]
  end

  test "the filters: state, label, missing, owner, customer", c do
    assert ids(page(c, c.hira, %{"state" => "in_progress"})) == [c.applied.id]
    assert ids(page(c, c.hira, %{"state" => "todo,done"})) == [c.saved.id, c.done.id]
    assert ids(page(c, c.hira, %{"label" => c.label.id})) == [c.applied.id]
    assert ids(page(c, c.hira, %{"missing" => "money"})) == [c.saved.id, c.done.id]
    assert ids(page(c, c.hira, %{"missing" => "cv"})) == [c.saved.id, c.done.id]
    assert ids(page(c, c.fiza, %{"owner" => "me"})) == [c.applied.id, c.done.id]
    assert ids(page(c, c.hira, %{"customer" => c.naveed.id})) == [c.saved.id]

    assert page(c, c.hira, %{"missing" => "recruiter"}) ==
             {:error, {:invalid, %{"missing" => ["is money or cv"]}}}

    other = label_fixture(scope_for(c.hira), c.frontend)

    assert page(c, c.hira, %{"label" => other.id}) ==
             {:error, {:invalid, %{"label" => ["has a label that is not this team's"]}}}
  end

  test "sort on any column, either way; nothing sorts last", c do
    assert ids(page(c, c.hira, %{"sort" => "title"})) == [c.saved.id, c.applied.id, c.done.id]

    assert ids(page(c, c.hira, %{"sort" => "title", "dir" => "desc"})) ==
             [c.done.id, c.applied.id, c.saved.id]

    assert ids(page(c, c.hira, %{"sort" => "applied"})) |> hd() == c.applied.id
    assert ids(page(c, c.hira, %{"sort" => "money", "dir" => "desc"})) |> hd() == c.applied.id
    assert ids(page(c, c.hira, %{"sort" => "labels"})) |> hd() == c.applied.id
    assert ids(page(c, c.hira, %{"sort" => "state"})) == [c.saved.id, c.applied.id, c.done.id]

    for column <- Data.Vocabulary.tracker_columns(),
        do: assert({:ok, %{total: 3}} = page(c, c.hira, %{"sort" => column}))

    assert {:error, {:invalid, %{"sort" => _}}} = page(c, c.hira, %{"sort" => "nope"})
    assert {:error, {:invalid, %{"dir" => _}}} = page(c, c.hira, %{"dir" => "up"})
  end

  test "group by state: rows run group by group, with the counts", c do
    assert {:ok, %{items: items, groups: groups}} = page(c, c.hira, %{"group" => "state"})
    assert Enum.map(items, & &1.state) == [:todo, :in_progress, :done]

    assert groups == [
             %{key: "todo", name: "To do", count: 1},
             %{key: "in_progress", name: "In progress", count: 1},
             %{key: "done", name: "Done", count: 1}
           ]

    assert {:ok, %{groups: [_, _]}} = page(c, c.hira, %{"group" => "customer"})
    assert {:ok, %{groups: groups}} = page(c, c.hira, %{"group" => "stage"})
    assert Enum.map(groups, & &1.name) == ["To do", "In progress · Applied", "Done · Applied"]
  end

  test "a member at hidden sees their own; another team's member finds nothing", c do
    {:ok, _} = Data.Teams.put_settings(c.backend.id, %{peer_leads: :hidden})
    assert ids(page(c, c.qasim)) == [c.saved.id]
    assert ids(page(c, c.muaz)) == []

    farah = member_fixture(c.frontend, :member, user_fixture())
    assert page(c, farah) == {:error, :not_found}

    assert Tracker.page(scope_for(c.hira), %{}, @now) ==
             {:error, {:invalid, %{"team_id" => ["is required"]}}}
  end

  test "keyset pages of 50 with the total; More continues after the last row", c do
    for _ <- 1..50,
        do:
          lead_fixture(scope_for(c.fiza),
            team: c.backend,
            last_activity_at: ~U[2026-11-01 09:00:00.000000Z]
          )

    {:ok, %{items: first, total: 53, next_cursor: cursor}} = page(c, c.hira)
    assert length(first) == 50 and is_binary(cursor)

    {:ok, %{items: rest, next_cursor: nil}} = page(c, c.hira, %{"cursor" => cursor})
    assert length(rest) == 3
    assert MapSet.disjoint?(MapSet.new(first, & &1.id), MapSet.new(rest, & &1.id))
  end

  test "the CSV: a BOM, every column, money as written, audited", c do
    assert {:ok, body, filename} =
             Tracker.csv(scope_for(c.hira), %{"team_id" => c.backend.id, "sort" => "title"}, @now)

    csv = IO.iodata_to_binary(body)
    assert String.starts_with?(csv, "﻿Applied,Title,Company,Source,Customer,Profile,Owner,")
    assert filename == "tracker-backend-squad-2026-11-11.csv"

    [_header | rows] = csv |> String.trim_trailing() |> String.split("\r\n")
    assert length(rows) == 3
    paid = Enum.find(rows, &String.contains?(&1, "Backend Developer"))
    assert paid =~ "PKR 300,000–400,000 / month"
    assert paid =~ "Priority client"
    assert paid =~ "In progress · Applied"
    # Source, workplace and engagement read as words, never as the vocabulary's keys.
    for row <- rows, do: refute(row =~ ~r/\b(company_site|on_site|full_time|part_time|yc_waas)\b/)

    [audit] =
      Data.Audit.list_for_subject(c.org.id, "teams", c.backend.id)
      |> Enum.filter(&(&1.action == "tracker_exported"))

    assert audit.after["rows"] == 3
  end
end
