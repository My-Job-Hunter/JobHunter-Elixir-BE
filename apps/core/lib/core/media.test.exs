defmodule Core.MediaTest do
  use Core.CoreCase, async: true

  import Ecto.Query, only: [from: 2]

  alias Core.Media
  alias Core.Storage

  @jpeg <<0xFF, 0xD8, 0xFF, 0xE0>> <> "JFIF and some bytes"
  @pdf "%PDF-1.7 a small document"
  @now ~U[2026-11-09 10:00:00.000000Z]

  setup do
    org = organisation_fixture()
    user = member_fixture(team_fixture(org), :member)
    %{scope: scope_for(user), other: scope_for(member_fixture(team_fixture(org), :member))}
  end

  defp declare(scope, attrs \\ %{}) do
    params =
      Map.merge(
        %{
          "media_kind" => "photo",
          "content_type" => "image/jpeg",
          "byte_count" => byte_size(@jpeg)
        },
        attrs
      )

    Media.create(scope, params, "/team/v1/media")
  end

  describe "the three steps" do
    test "reserve, store, confirm; then a signed read", %{scope: scope} do
      assert {:ok, media, target} = declare(scope, %{"original_filename" => "me.jpg"})
      assert media.uploaded_at == nil
      assert media.organisation_id == scope.organisation.id
      assert target == %{url: "/team/v1/media/#{media.id}/blob", method: "PUT", headers: %{}}

      assert Media.store(scope, media.id, @jpeg) == :ok

      assert {:ok, confirmed} =
               Media.confirm(scope, media.id, %{"width_px" => 10, "height_px" => "12"}, @now)

      assert confirmed.uploaded_at == @now
      assert confirmed.width_px == 10 and confirmed.height_px == 12
      assert confirmed.sha256 == :crypto.hash(:sha256, @jpeg)

      "/media/" <> rest = Media.link(media.id)
      [_id, "t=" <> token] = String.split(rest, "?")
      assert {:ok, read, @jpeg} = Media.read(media.id, token)
      assert read.id == media.id
    end

    test "confirming before the bytes arrived is refused", %{scope: scope} do
      {:ok, media, _target} = declare(scope)
      assert Media.confirm(scope, media.id, %{}, @now) == {:error, {:missing, :blob}}
    end

    test "somebody else's row does not exist", %{scope: scope, other: other} do
      {:ok, media, _target} = declare(scope)
      assert Media.store(other, media.id, @jpeg) == {:error, :not_found}
      assert Media.confirm(other, media.id, %{}, @now) == {:error, :not_found}
      assert Media.store(scope, Ecto.UUID.generate(), @jpeg) == {:error, :not_found}
      assert Media.store(scope, "nonsense", @jpeg) == {:error, :not_found}
    end
  end

  describe "refusals" do
    test "a type off the allowlist, or wrong for the kind", %{scope: scope} do
      assert declare(scope, %{"content_type" => "image/svg+xml"}) ==
               {:error, :file_type_not_allowed}

      assert declare(scope, %{"content_type" => "application/pdf"}) ==
               {:error, :file_type_not_allowed}

      assert {:ok, _m, _t} =
               declare(scope, %{"media_kind" => "document", "content_type" => "application/pdf"})

      assert {:ok, _m, _t} =
               declare(scope, %{"media_kind" => "attachment", "content_type" => "application/pdf"})

      assert declare(scope, %{"media_kind" => "video"}) == {:error, {:missing, :media_kind}}
      assert declare(scope, %{"content_type" => nil}) == {:error, {:missing, :content_type}}
    end

    test "too large, declared or sent", %{scope: scope} do
      cap = Storage.max_bytes(:photo)
      assert declare(scope, %{"byte_count" => cap + 1}) == {:error, {:file_too_large, cap}}
      assert declare(scope, %{"byte_count" => "zero"}) == {:error, {:missing, :byte_count}}

      {:ok, media, _target} = declare(scope)
      big = @jpeg <> :binary.copy("x", cap)
      assert Media.store(scope, media.id, big) == {:error, {:file_too_large, cap}}
    end

    test "bytes that are not the declared type", %{scope: scope} do
      {:ok, media, _target} = declare(scope)
      assert Media.store(scope, media.id, @pdf) == {:error, :file_mismatch}
      assert Media.store(scope, media.id, "just words") == {:error, :file_mismatch}
    end

    test "a read without a valid link, or of an unconfirmed file, is not found", %{scope: scope} do
      {:ok, media, _target} = declare(scope)
      :ok = Media.store(scope, media.id, @jpeg)

      assert Media.read(media.id, nil) == {:error, :not_found}
      assert Media.read(media.id, "forged") == {:error, :not_found}
      "/media/" <> rest = Media.link(media.id)
      [_id, "t=" <> token] = String.split(rest, "?")
      assert Media.read(media.id, token) == {:error, :not_found}
      assert Media.read(Ecto.UUID.generate(), token) == {:error, :not_found}
    end

    test "a link signed for another file does not open this one", %{scope: scope} do
      {:ok, a, _t} = declare(scope)
      {:ok, b, _t} = declare(scope)

      for m <- [a, b] do
        :ok = Media.store(scope, m.id, @jpeg)
        {:ok, _confirmed} = Media.confirm(scope, m.id, %{}, @now)
      end

      "/media/" <> rest = Media.link(a.id)
      [_id, "t=" <> token] = String.split(rest, "?")

      assert Media.read(b.id, token) == {:error, :not_found}
    end
  end

  test "own_uploaded wants a confirmed file of the kind", %{scope: scope, other: other} do
    {:ok, media, _target} = declare(scope)
    assert Media.own_uploaded(scope, media.id, :photo) == {:error, :not_found}
    :ok = Media.store(scope, media.id, @jpeg)
    {:ok, _confirmed} = Media.confirm(scope, media.id, %{}, @now)

    assert {:ok, %{id: id}} = Media.own_uploaded(scope, media.id, :photo)
    assert id == media.id
    assert Media.own_uploaded(scope, media.id, :document) == {:error, :not_found}
    assert Media.own_uploaded(other, media.id, :photo) == {:error, :not_found}
  end

  test "the sweep removes rows reserved a day ago that were never confirmed, and their bytes", %{
    scope: scope
  } do
    {:ok, stale, _t} = declare(scope)
    :ok = Media.store(scope, stale.id, @jpeg)
    {:ok, fresh, _t} = declare(scope)
    {:ok, done, _t} = declare(scope)
    :ok = Media.store(scope, done.id, @jpeg)
    {:ok, _confirmed} = Media.confirm(scope, done.id, %{}, @now)

    old = DateTime.add(@now, -2, :day)

    Repo.update_all(from(m in Data.Files.Media, where: m.id in ^[stale.id, done.id]),
      set: [inserted_at: old]
    )

    assert Media.sweep_unconfirmed(@now) == 1
    assert Data.Files.get(stale.id) == nil
    assert Storage.size(stale.storage_key) == nil
    assert Data.Files.get(fresh.id)
    assert Data.Files.get(done.id)
    assert Media.sweep_unconfirmed(@now) == 0
  end
end
