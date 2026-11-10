defmodule Core.Storage.LocalTest do
  use ExUnit.Case, async: true

  alias Core.Storage
  alias Core.Storage.Local

  test "a key is generated from the type, never the filename, and sharded" do
    key = Storage.key_for("application/pdf")
    assert [shard, file] = String.split(key, "/")
    assert String.length(shard) == 2
    assert String.ends_with?(file, ".pdf")
    assert String.ends_with?(Storage.key_for("text/markdown"), ".md")
    assert String.ends_with?(Storage.key_for("application/x-unknown"), ".bin")
  end

  test "put, size, fetch and delete under the root" do
    key = Storage.key_for("text/plain")

    assert Local.put(key, "hello") == :ok
    assert Local.size(key) == 5
    assert Local.fetch(key) == {:ok, "hello"}
    assert Local.delete(key) == :ok
    assert Local.size(key) == nil
    assert Local.delete(key) == :ok
  end

  test "a key outside the root is refused on the expanded path" do
    assert Local.put("../escape.txt", "x") == {:error, :outside_root}
    assert Local.put("a/./../../etc", "x") == {:error, :outside_root}
    assert Local.put("/etc/passwd", "x") == {:error, :outside_root}
    assert Local.fetch("../escape.txt") == {:error, :outside_root}
  end

  test "the caps are per kind (QP1-3)" do
    assert Storage.max_bytes(:photo) == 5_000
    assert Storage.max_bytes(:document) == 12_000
    assert Storage.max_bytes(:attachment) == 12_000
  end

  test "the upload target is our own blob route" do
    assert Local.upload_target("k", "id-1", "/team/v1/media") ==
             {:ok, %{url: "/team/v1/media/id-1/blob", method: "PUT", headers: %{}}}
  end
end
