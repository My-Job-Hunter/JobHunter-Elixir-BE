defmodule Core.Media.SweepWorkerTest do
  use Core.CoreCase, async: true

  import Ecto.Query, only: [from: 2]

  alias Core.Media.SweepWorker
  alias Data.Files

  test "sweeps an abandoned reservation, keeps a fresh one; runs twice" do
    org = organisation_fixture()
    user = user_fixture()
    scope = scope_for(user, organisation: org)
    params = %{"media_kind" => "document", "content_type" => "text/plain", "byte_count" => 5}

    {:ok, stale, _target} = Core.Media.create(scope, params, "/media")
    {:ok, fresh, _target} = Core.Media.create(scope, params, "/media")

    two_days_ago = DateTime.add(DateTime.utc_now(), -2, :day)

    {1, _rows} =
      Repo.update_all(
        from(m in Data.Files.Media, where: m.id == ^stale.id),
        set: [inserted_at: two_days_ago]
      )

    assert SweepWorker.perform(%Oban.Job{args: %{}}) == :ok
    assert Files.get(stale.id) == nil
    assert Files.get(fresh.id)
    assert SweepWorker.perform(%Oban.Job{args: %{}}) == :ok
    assert Files.get(fresh.id)
  end

  test "the crontab names it daily at 03:20" do
    {Oban.Plugins.Cron, crontab: crontab} =
      :core
      |> Application.fetch_env!(Oban)
      |> Keyword.fetch!(:plugins)
      |> List.keyfind(Oban.Plugins.Cron, 0)

    assert {"20 3 * * *", SweepWorker} in crontab
  end
end
