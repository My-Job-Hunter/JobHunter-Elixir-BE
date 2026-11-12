defmodule Core.Extension.ContextTest do
  @moduledoc """
  AQ-05 §8 (P5.2): each identity rule, from two staff sessions — the
  acting profile picked from the page's account, asked when it names
  several, the list when it names none, and the team.
  """

  use Core.CoreCase, async: true

  alias Core.Extension.Context

  @now ~U[2026-11-11 09:00:00.000000Z]

  setup do
    c = board_cast_fixture()
    elixir = profile_fixture(c.naveed, title: "Elixir backend")
    naveed_go = profile_fixture(c.naveed, title: "Golang")
    ai = profile_fixture(c.imran, title: "AI/ML engineer")

    tanweer_in =
      channel_fixture(c.tanweer,
        handle: "https://www.linkedin.com/in/tanweer/",
        operated_by: :agency
      )

    naveed_in = channel_fixture(c.naveed, handle: "https://www.linkedin.com/in/naveed-example/")
    imran_in = channel_fixture(c.imran, handle: "https://www.linkedin.com/in/imran-example/")

    :ok = Data.Profiles.put_channels(c.golang, [tanweer_in.id])
    :ok = Data.Profiles.put_channels(elixir, [naveed_in.id])
    :ok = Data.Profiles.put_channels(naveed_go, [naveed_in.id])
    :ok = Data.Profiles.put_channels(ai, [imran_in.id])

    Map.merge(c, %{
      elixir: elixir,
      naveed_go: naveed_go,
      ai: ai,
      tanweer_in: tanweer_in,
      naveed_in: naveed_in,
      imran_in: imran_in,
      s_fiza: %{scope_for(c.fiza) | via: :extension},
      s_muaz: %{scope_for(c.muaz) | via: :extension}
    })
  end

  defp context(scope, identity, site \\ "linkedin") do
    {:ok, context} = Context.get(scope, %{"site" => site, "identity" => identity}, @now)
    context
  end

  defp titles(context), do: Enum.map(context.profiles, & &1.title)

  test "Tanweer's LinkedIn, as read off the page: Golang backend in Backend squad, picked", c do
    ctx = context(c.s_fiza, "https://www.linkedin.com/in/Tanweer/overlay/contact-info/")

    assert ctx.identity.state == "channel"
    assert ctx.identity.channel.id == c.tanweer_in.id
    assert ctx.identity.channel.operated_by == :agency
    assert ctx.pick == %{profile_id: c.golang.id, team_id: c.backend.id}

    assert [%{id: id, matched: true, teams: [%{name: "Backend squad"}]} | _rest] = ctx.profiles
    assert id == c.golang.id

    # The channel's last seen moves.
    assert Data.Channels.get(c.tanweer_in.id).last_seen_at == @now
  end

  test "Naveed's LinkedIn works for two profiles: both matched, none picked", c do
    ctx = context(c.s_fiza, "linkedin.com/in/naveed-example?trk=x")

    assert ctx.identity.state == "channel"
    assert ctx.pick == nil

    matched = for p <- ctx.profiles, p.matched, do: p.id
    assert Enum.sort(matched) == Enum.sort([c.elixir.id, c.naveed_go.id])
    # Matched first.
    assert Enum.take(ctx.profiles, 2) |> Enum.all?(& &1.matched)
  end

  test "an account nobody registered: unknown, and every profile one may act for", c do
    ctx = context(c.s_fiza, "https://www.linkedin.com/in/fiza-own-account/")

    assert ctx.identity == %{state: "unknown", channel: nil}
    assert ctx.pick == nil
    refute Enum.any?(ctx.profiles, & &1.matched)
    assert "Golang backend" in titles(ctx)
  end

  test "nothing read yet: none", c do
    assert context(c.s_fiza, nil).identity == %{state: "none", channel: nil}
    assert context(c.s_fiza, "").identity.state == "none"
  end

  test "Fiza sees Imran's profile under Frontend squad, and Muaz does not", c do
    fiza = context(c.s_fiza, nil)
    muaz = context(c.s_muaz, nil)

    assert %{teams: [%{name: "Frontend squad"}]} = Enum.find(fiza.profiles, &(&1.id == c.ai.id))
    refute Enum.any?(muaz.profiles, &(&1.id == c.ai.id))
  end

  test "a channel of a customer one doesn't serve is named to nobody", c do
    ctx = context(c.s_muaz, "https://www.linkedin.com/in/imran-example/")

    assert ctx.identity == %{state: "unknown", channel: nil}
    assert Data.Channels.get(c.imran_in.id).last_seen_at == nil
  end

  test "a customer served by two of your teams: both, and the team is asked", c do
    {:ok, _link} = Data.Customers.assign_team(c.tanweer, c.frontend.id, ~D[2026-11-11])
    ctx = context(c.s_fiza, "https://www.linkedin.com/in/tanweer/")

    golang = Enum.find(ctx.profiles, &(&1.id == c.golang.id))
    assert Enum.map(golang.teams, & &1.name) == ["Backend squad", "Frontend squad"]
    assert ctx.pick == %{profile_id: c.golang.id, team_id: nil}

    # Muaz is in one of them only.
    muaz = context(c.s_muaz, "https://www.linkedin.com/in/tanweer/")
    assert muaz.pick == %{profile_id: c.golang.id, team_id: c.backend.id}
  end

  test "the system admin: every serving team, and is_admin", c do
    ctx = context(%{scope_for(c.dawud) | via: :extension}, nil)

    assert ctx.me.is_admin
    assert %{teams: [%{name: "Frontend squad"}]} = Enum.find(ctx.profiles, &(&1.id == c.ai.id))
    assert %{teams: [%{name: "Backend squad"}]} = Enum.find(ctx.profiles, &(&1.id == c.golang.id))
  end

  test "a paused customer's profiles are not offered", c do
    {:ok, _paused} = Data.Customers.change_status(c.naveed, :paused, ~D[2026-11-11])
    ctx = context(c.s_fiza, "https://www.linkedin.com/in/naveed-example/")

    refute Enum.any?(ctx.profiles, &(&1.id in [c.elixir.id, c.naveed_go.id]))
    assert ctx.pick == nil
  end

  test "each profile's CVs, the default marked", c do
    cv = document_fixture(c.golang, kind: :cv, label: "Tanweer CV")
    _link = document_fixture(c.golang, kind: :portfolio)
    {:ok, _default} = Data.Profiles.put_default_document(c.golang, cv.id)

    ctx = context(c.s_fiza, nil)
    golang = Enum.find(ctx.profiles, &(&1.id == c.golang.id))
    assert golang.cvs == [%{id: cv.id, label: "Tanweer CV", version: 1, is_default: true}]
  end

  test "the person and the site", c do
    ctx = context(c.s_fiza, nil)
    assert ctx.me.person.name == "Fiza"
    refute ctx.me.is_admin

    assert {:error, {:invalid, %{"site" => _}}} =
             Context.get(c.s_fiza, %{"site" => "indeed"}, @now)
  end

  test "an Upwork page reads an Upwork account: a LinkedIn link there names nothing", c do
    ctx = context(c.s_fiza, "https://www.linkedin.com/in/tanweer/", "upwork")
    assert ctx.identity.state == "unknown"
  end
end
