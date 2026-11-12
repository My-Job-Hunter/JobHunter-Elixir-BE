defmodule Core.ExtensionAccessMatrixTest do
  @moduledoc """
  AQ-05 §4, cell by cell, over the cast: Fiza in both teams, Muaz in
  Backend only, Hira a team lead of both, Dawud the system admin, Tanweer
  (a customer, whose account cannot connect) and a signed-in stranger. An
  unseen row is `:not_found`, never `:forbidden`. Then the same rows
  through the contexts: the profiles offered, the lookup's team, *Save*
  in a team that doesn't serve the customer.
  """

  use Core.CoreCase, async: true

  alias Core.Access
  alias Core.Extension.Context
  alias Core.Ingest.Extension

  @now ~U[2026-11-11 09:00:00.000000Z]
  @staff [:connect, :use, :report_misses]
  @admin [:list_devices, :read_health, :read_configs]

  setup do
    c = board_cast_fixture()
    ai = profile_fixture(c.imran, title: "AI/ML engineer")

    scopes = %{
      fiza: scope_for(c.fiza),
      muaz: scope_for(c.muaz),
      hira: scope_for(c.hira),
      dawud: scope_for(c.dawud),
      tanweer: customer_scope_for(c.tanweer),
      stranger: scope_for(user_fixture())
    }

    device = device_fixture(scopes.fiza)
    Map.merge(c, %{ai: ai, scopes: scopes, device: device})
  end

  @extension [
    fiza: %{ok: @staff, not_found: @admin},
    muaz: %{ok: @staff, not_found: @admin},
    hira: %{ok: @staff, not_found: @admin},
    dawud: %{ok: @staff ++ @admin, not_found: []},
    tanweer: %{ok: [], not_found: @staff ++ @admin},
    stranger: %{ok: [], not_found: @staff ++ @admin}
  ]

  test "connecting, the extension's routes, the misses, and Settings › Extension", c do
    for {chair, cells} <- @extension,
        {answer, actions} <- cells,
        action <- actions do
      got = Access.why_not(c.scopes[chair], action, :extension)
      want = if answer == :ok, do: :ok, else: {:error, :not_found}
      assert got == want, "#{chair} #{action}: #{inspect(got)}"
    end
  end

  @device [
    fiza: :ok,
    dawud: :ok,
    muaz: :not_found,
    hira: :not_found,
    tanweer: :not_found,
    stranger: :not_found
  ]

  test "a device: its owner's and the system admin's, nobody else's", c do
    for {chair, answer} <- @device, action <- [:read, :disconnect] do
      got = Access.why_not(c.scopes[chair], action, {:device, c.device})
      want = if answer == :ok, do: :ok, else: {:error, :not_found}
      assert got == want, "#{chair} #{action} the device: #{inspect(got)}"
    end
  end

  test "the profiles offered: live profiles of customers a team of yours serves; the admin's every team",
       c do
    offered = fn chair ->
      {:ok, ctx} =
        Context.get(%{c.scopes[chair] | via: :extension}, %{"site" => "linkedin"}, @now)

      Map.new(ctx.profiles, &{&1.id, Enum.map(&1.teams, fn t -> t.name end)})
    end

    assert offered.(:fiza)[c.ai.id] == ["Frontend squad"]
    assert offered.(:fiza)[c.golang.id] == ["Backend squad"]
    refute Map.has_key?(offered.(:muaz), c.ai.id)
    assert offered.(:muaz)[c.golang.id] == ["Backend squad"]
    assert offered.(:hira)[c.ai.id] == ["Frontend squad"]
    assert offered.(:dawud)[c.ai.id] == ["Frontend squad"]

    assert Context.get(c.scopes.tanweer, %{"site" => "linkedin"}, @now) == {:error, :not_found}
    assert Context.get(c.scopes.stranger, %{"site" => "linkedin"}, @now) == {:error, :not_found}
  end

  test "lookup: a team one is in, the admin any; else not found", c do
    url = "https://www.linkedin.com/jobs/view/4012233871/"

    for {chair, answer} <- [fiza: :ok, hira: :ok, dawud: :ok, muaz: :not_found] do
      got =
        Extension.lookup(
          %{c.scopes[chair] | via: :extension},
          %{"url" => url, "team_id" => c.frontend.id},
          @now
        )

      if answer == :ok,
        do: assert({:ok, %{key: "linkedin:4012233871"}} = got),
        else: assert(got == {:error, :not_found}, "#{chair}: #{inspect(got)}")
    end
  end

  test "save: P4a's rules for that verb in that team", c do
    body = fn team, profile ->
      %{
        "request_id" => Ecto.UUID.generate(),
        "team_id" => team.id,
        "profile_id" => profile.id,
        "url" => "https://www.linkedin.com/jobs/view/#{System.unique_integer([:positive])}/",
        "fields" => %{"title" => "Go Engineer"}
      }
    end

    fiza = %{c.scopes.fiza | via: :extension}
    muaz = %{c.scopes.muaz | via: :extension}

    assert {:ok, {:created, _}} = Extension.save(fiza, body.(c.frontend, c.ai), @now)
    assert Extension.save(muaz, body.(c.frontend, c.ai), @now) == {:error, :not_found}
    # Muaz does not reach Imran at all.
    assert Extension.save(muaz, body.(c.backend, c.ai), @now) == {:error, :not_found}

    assert Extension.save(fiza, body.(c.frontend, c.golang), @now) ==
             {:error, {:forbidden, "Frontend squad doesn't serve Tanweer."}}

    assert Extension.save(c.scopes.tanweer, body.(c.backend, c.golang), @now) ==
             {:error, :not_found}
  end
end
