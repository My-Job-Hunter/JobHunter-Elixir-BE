defmodule Mix.Tasks.Aq.SeedStandard do
  @shortdoc "Ensures the standard test set: Super Admin, Team 1–3, leads, staff, customers, 21 jobs (dev only)"

  @moduledoc """
  The standard test set (`Core.Standard`; `docs/TEST-ACCOUNTS.md` lists every
  account): Super Admin as the one system admin, Team 1, 2 and 3 with a
  lead and a staff member each, an active customer per team with a portal
  account and a profile, and 21 jobs from seven boards.

      mix aq.seed_standard
      mix ecto.reset              # every seed, this one last

  **Dev only.** Outside dev it says it skips and does nothing; `seeds/0` in
  the umbrella's `mix.exs` runs it after `aq.seed_demo` for every
  environment but test. Idempotent: run it again and it makes nothing. On a
  database whose system admin is somebody else (an older world with Dawud)
  it stops and says how to fix it.

  It lives in `core`, not `data` with the other seed tasks, because it
  makes everything through the front door's code and `data` cannot name
  `core`.
  """

  use Mix.Task

  alias Core.Standard
  alias Data.Scope

  @requirements ["app.start"]

  # `password123` for every account: the user's rule (2026-11-12) — every
  # test account signs in with the standard password. **Dev only**: a dev
  # server skips the worst-list for it (`config :core, dev_worst_passwords:
  # true`, dev.exs alone); test and a release keep the list, and this task
  # does nothing outside dev.
  @password "password123"

  @impl Mix.Task
  def run(_args) do
    case Mix.env() do
      :dev ->
        ensure()

      env ->
        Mix.shell().info("Standard set: skipped — it is dev only, and this is #{env}.")
    end
  end

  defp ensure do
    result =
      Data.Seeds.quietly(fn -> Standard.ensure(Scope.system(), @password, Core.Clock.now()) end)

    case result do
      {:ok, summary} -> report(summary)
      {:error, words} when is_binary(words) -> Mix.raise(words)
      {:error, reason} -> Mix.raise("Could not ensure the standard set: #{inspect(reason)}")
    end
  end

  defp report(%{made: made, kept: kept}) do
    shell = Mix.shell()

    case made do
      [] -> shell.info("Standard set: all #{kept} already in place; made nothing.")
      _some -> shell.info("Standard set: made #{length(made)}, kept #{kept}.")
    end

    shell.info("  Every account signs in with #{@password} (docs/TEST-ACCOUNTS.md):")

    for account <- Standard.accounts() do
      team = if account.team, do: ", #{account.team}", else: ""
      shell.info("    #{String.pad_trailing(account.email, 26)} #{role(account.role)}#{team}")
    end
  end

  defp role(:system_admin), do: "system admin"
  defp role(:team_lead), do: "team lead"
  defp role(:staff), do: "staff"
  defp role(:customer), do: "customer (portal)"
end
