defmodule Data.Seeds.ExtensionConfigsTest do
  @moduledoc """
  AQ-05 §13: each site's selector document is version 1 wherever the site
  has none, and a site that has one is kept — the seed never publishes a
  second version (that is `mix aq.ext_config`'s, which validates first).
  """

  use Data.DataCase, async: true

  alias Data.Extension
  alias Data.Seeds.ExtensionConfigs

  setup do
    dir = Path.join(System.tmp_dir!(), "aq-seed-ext-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  test "the files are where the seed looks" do
    assert File.dir?(ExtensionConfigs.dir())
  end

  test "a site with a version is kept, whatever its file says now", %{dir: dir} do
    Repo.delete_all(Data.Extension.Config)

    {:ok, {:published, v1}} =
      Extension.publish(:linkedin, ~s({"site":"linkedin"}), DateTime.utc_now())

    File.write!(Path.join(dir, "linkedin.json"), ~s({"site":"linkedin","changed":true}))

    assert ExtensionConfigs.load(dir: dir) == %{inserted: 0, kept: 1}
    assert Extension.live_config(:linkedin).id == v1.id
  end

  test "an empty table: each file is version 1", %{dir: dir} do
    Repo.delete_all(Data.Extension.Config)
    File.write!(Path.join(dir, "upwork.json"), ~s({"site":"upwork"}))

    assert ExtensionConfigs.load(dir: dir) == %{inserted: 1, kept: 0}
    assert %{version: 1, body: ~s({"site":"upwork"})} = Extension.live_config(:upwork)
    assert Extension.live_config(:linkedin) == nil

    assert ExtensionConfigs.load(dir: dir) == %{inserted: 0, kept: 1}
  end
end
