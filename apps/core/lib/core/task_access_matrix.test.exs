defmodule Core.TaskAccessMatrixTest do
  @moduledoc """
  AQ-02 §6.3 with AQ-03B §3.2's levels, cell by cell: the task rows of the
  access matrix over the P1 cast and six tasks — T1 Fiza's; T2 Qasim's; T3
  about Tanweer, given to him, by Hira, primary Fiza; T4 Frontend's, about
  Imran, primary Hira; T5 Hira's draft; T6 Qasim's, watched by Muaz.

  Every action of `Core.Access.Tasks.actions/0`, from Dawud (the system admin, in
  no team), Hira (lead of both), Bilal (lead of Backend), Fiza (member of
  both), Qasim and Muaz (members of Backend), the `:admin` chair (Dawud again: one system admin), Farah (a
  member of Frontend only: the other team), and the portal scopes of
  Tanweer and Naveed — **three times**: with both teams' `peer_tasks` at
  `hidden`, `view` and `edit`. Each row also holds the board's query
  (`Core.Tasks.Visibility`) to the same answer as the rule for one task:
  the tasks a person lists are exactly those they read.
  """

  use Core.CoreCase, async: true

  alias Core.Access
  alias Core.Access.Tasks, as: TaskAccess
  alias Core.Tasks
  alias Core.Tasks.Visibility
  alias Data.Tasks, as: Store

  @all TaskAccess.actions()
  @talk [:read, :comment, :comment_staff_only, :watch]
  @portal_ok [:read, :comment, :files, :tick, :complete]
  @tasks [:t1, :t2, :t3, :t4, :t5, :t6]

  # Lead, admin or author: every action, and a non-draft is never deleted.
  @full %{ok: @all -- [:delete], forbidden: [:delete]}
  # The author of a draft: everything.
  @drafter %{ok: @all}
  # An assignee who is a member, or a member at `edit`: changes it, but not
  # who the customer sees it as, and never deletes it.
  @changer %{ok: @all -- [:delete, :change_visibility], forbidden: [:delete, :change_visibility]}
  # A member at `view`, or a watcher: talks, never changes.
  @talker %{ok: @talk, forbidden: @all -- @talk}
  @hidden %{not_found: @all}
  @given %{ok: @portal_ok, forbidden: @all -- @portal_ok}

  # What the level does not change: the leads, the admins, the customers.
  @fixed [
    {:dawud, %{t1: @full, t2: @full, t3: @full, t4: @full, t5: @hidden, t6: @full}},
    {:hira, %{t1: @full, t2: @full, t3: @full, t4: @full, t5: @drafter, t6: @full}},
    {:bilal, %{t1: @full, t2: @full, t3: @full, t4: @hidden, t5: @hidden, t6: @full}},
    {:admin, %{t1: @full, t2: @full, t3: @full, t4: @full, t5: @hidden, t6: @full}},
    {:tanweer, %{t1: @hidden, t2: @hidden, t3: @given, t4: @hidden, t5: @hidden, t6: @hidden}},
    {:naveed, Map.new(@tasks, &{&1, @hidden})}
  ]

  @levels [
    hidden: [
      {:fiza, %{t1: @full, t2: @hidden, t3: @changer, t4: @hidden, t5: @hidden, t6: @hidden}},
      {:qasim, %{t1: @hidden, t2: @full, t3: @hidden, t4: @hidden, t5: @hidden, t6: @full}},
      {:muaz, %{t1: @hidden, t2: @hidden, t3: @hidden, t4: @hidden, t5: @hidden, t6: @talker}},
      {:farah, Map.new(@tasks, &{&1, @hidden})}
    ],
    view: [
      {:fiza, %{t1: @full, t2: @talker, t3: @changer, t4: @talker, t5: @hidden, t6: @talker}},
      {:qasim, %{t1: @talker, t2: @full, t3: @talker, t4: @hidden, t5: @hidden, t6: @full}},
      {:muaz, %{t1: @talker, t2: @talker, t3: @talker, t4: @hidden, t5: @hidden, t6: @talker}},
      {:farah, %{t1: @hidden, t2: @hidden, t3: @hidden, t4: @talker, t5: @hidden, t6: @hidden}}
    ],
    edit: [
      {:fiza, %{t1: @full, t2: @changer, t3: @changer, t4: @changer, t5: @hidden, t6: @changer}},
      {:qasim, %{t1: @changer, t2: @full, t3: @changer, t4: @hidden, t5: @hidden, t6: @full}},
      {:muaz,
       %{t1: @changer, t2: @changer, t3: @changer, t4: @hidden, t5: @hidden, t6: @changer}},
      {:farah, %{t1: @hidden, t2: @hidden, t3: @hidden, t4: @changer, t5: @hidden, t6: @hidden}}
    ]
  ]

  @view_words "You can see this, but only its people or a team lead can change it."
  @change_words "Only the people on this task, or a lead, can change it."

  setup do
    c = board_cast_fixture()
    farah = member_fixture(c.frontend, :member, user_fixture(display_name: "Farah"))
    # One system admin (QP4a-21): the `:admin` chair is Dawud, in no team.
    admin = c.dawud
    hira = scope_for(c.hira)

    tasks = %{
      t1: task_fixture(scope_for(c.fiza), team: c.backend, primary: c.fiza),
      t2: task_fixture(scope_for(c.qasim), team: c.backend, primary: c.qasim),
      t3:
        task_fixture(hira,
          team: c.backend,
          customer: c.tanweer,
          customer_access: :assigned,
          primary: c.fiza
        ),
      t4: task_fixture(hira, team: c.frontend, customer: c.imran, primary: c.hira),
      t5: task_fixture(hira, team: c.backend, state: :draft),
      t6: task_fixture(scope_for(c.qasim), team: c.backend, watchers: [c.muaz])
    }

    Map.merge(c, %{tasks: tasks, farah: farah, admin: admin})
  end

  defp put_level(c, level) do
    for team <- [c.backend, c.frontend],
        do: {:ok, _settings} = Data.Teams.put_settings(team.id, %{peer_tasks: level})
  end

  defp scope_of(c, who) when who in [:tanweer, :naveed],
    do: customer_scope_for(Map.fetch!(c, who))

  defp scope_of(c, who), do: scope_for(Map.fetch!(c, who))

  for {level, rows} <- @levels, {who, cells} <- @fixed ++ rows do
    test "#{who}, peer_tasks #{level}", c do
      who = unquote(who)
      put_level(c, unquote(level))
      scope = scope_of(c, who)
      cells = unquote(Macro.escape(cells))

      assert Enum.sort(Map.keys(cells)) == @tasks, "#{who} names every task"

      for {key, expected} <- cells do
        task = Map.fetch!(c.tasks, key)

        table =
          for {outcome, actions} <- expected, action <- actions, into: %{}, do: {action, outcome}

        assert Enum.sort(Map.keys(table)) == Enum.sort(@all),
               "#{who}/#{key} must name every action"

        for {action, outcome} <- table do
          got = Access.why_not(scope, action, {:task, task})

          assert classify(got) == outcome,
                 "#{who} #{action} #{key}: expected #{outcome}, got #{inspect(got)}"
        end
      end

      # The board's query agrees with the rule for one task.
      readable =
        for {key, cells} <- cells, :read in Map.get(cells, :ok, []), do: c.tasks[key].id

      listed = scope |> Visibility.filter() |> Store.list() |> Enum.map(& &1.id)
      assert Enum.sort(listed) == Enum.sort(readable), "#{who} lists what they read"
    end
  end

  defp classify(:ok), do: :ok
  defp classify({:error, :not_found}), do: :not_found
  defp classify({:error, {:forbidden, words}}) when is_binary(words), do: :forbidden

  # ── Beyond the cells ────────────────────────────────────────────────────────

  test "the words: a member at view hears the level's, a watcher P2's; hidden is 404", c do
    now = DateTime.utc_now()
    from = %{"from" => "todo"}

    put_level(c, :hidden)
    assert Tasks.get(scope_for(c.muaz), c.tasks.t1.id, now) == {:error, :not_found}

    assert Tasks.Act.run(scope_for(c.muaz), :start, c.tasks.t6.id, from, now) ==
             {:error, {:forbidden, @change_words}}

    put_level(c, :view)
    muaz = scope_for(c.muaz)

    assert {:ok, %{id: id, can: %{edit: false, share: true}}} =
             Tasks.get(muaz, c.tasks.t1.id, now)

    assert id == c.tasks.t1.id

    assert Tasks.Act.run(muaz, :start, c.tasks.t1.id, from, now) ==
             {:error, {:forbidden, @view_words}}

    put_level(c, :edit)

    assert {:ok, %{state: :in_progress}} =
             Tasks.Act.run(scope_for(c.muaz), :start, c.tasks.t1.id, from, now)
  end

  test "at edit a member still may not change who the customer sees it as, nor delete a draft",
       c do
    put_level(c, :edit)
    qasim = scope_for(c.qasim)

    assert {:error, {:forbidden, "Only the task's author or a lead can change who sees it."}} =
             Access.why_not(qasim, :change_visibility, {:task, c.tasks.t3})

    draft = task_fixture(scope_for(c.fiza), team: c.backend, state: :draft)
    assert Access.why_not(qasim, :delete, {:task, draft}) == {:error, :not_found}
  end

  test "only staff in the team, or an admin, make a team's task; the customer makes their own",
       c do
    stranger = scope_for(user_fixture(), organisation: c.org)
    muaz = scope_for(c.muaz)

    assert Access.can?(muaz, :create, {:task, %{team_id: c.backend.id}})

    assert Access.why_not(muaz, :create, {:task, %{team_id: c.frontend.id}}) ==
             {:error, :not_found}

    assert Access.why_not(muaz, :create, {:task, %{team_id: nil}}) == {:error, :not_found}
    assert Access.can?(scope_for(c.admin), :create, {:task, %{team_id: c.frontend.id}})

    assert Access.why_not(stranger, :create, {:task, %{team_id: c.backend.id}}) ==
             {:error, :not_found}

    assert Access.can?(customer_scope_for(c.tanweer), :create, {:task, %{team_id: nil}})
  end

  test "a task needs its team: the column is not null", c do
    assert {:error, changeset} =
             Store.create(%{
               organisation_id: c.org.id,
               title: "Nowhere",
               state: :todo,
               customer_access: :none,
               source: :staff
             })

    assert {"can't be blank", _opts} = changeset.errors[:team_id]
  end
end
