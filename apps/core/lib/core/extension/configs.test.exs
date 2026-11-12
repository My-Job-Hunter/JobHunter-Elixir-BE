defmodule Core.Extension.ConfigsTest do
  @moduledoc """
  AQ-05 §11.4's contract 1 (`validate/1`), **the repo's own files against
  it** (§13: whatever `apps/core/priv/extension` holds), and publishing:
  a changed file is a new version, an unchanged one is kept.
  """

  use Core.CoreCase, async: true

  alias Core.Extension.Configs
  alias Data.Extension, as: Store
  alias Data.Extension.Config

  doctest Configs

  @now ~U[2026-11-11 09:00:00.000000Z]

  @valid %{
    "site" => "upwork",
    "contract" => 1,
    "pages" => %{
      "job" => %{"url" => ["/jobs/~0", "re:^/details/~0[0-9a-f]+"], "ready" => ["h4.title"]},
      "proposal" => %{"url" => ["/proposals/"], "ready" => ["form"]}
    },
    "fields" => %{
      "title" => %{"on" => "job", "css" => ["h4.title"], "read" => "text", "required" => true},
      "skills_text" => %{
        "on" => "job",
        "css" => [".skills a"],
        "read" => "text",
        "required" => false,
        "all" => true
      },
      "upwork.client.rating_text" => %{
        "on" => "job",
        "css" => ["[data-test=rating]"],
        "read" => "attr:aria-label",
        "required" => false
      }
    },
    "identity" => %{"css" => ["a[href*='/freelancers/~0']"], "read" => "href"},
    "confirmation" => %{"on" => "proposal", "css" => [".done"], "read" => "present"}
  }

  describe "the repo's files" do
    for site <- Data.Vocabulary.ext_sites() do
      test "#{site}.json, if it is there, keeps contract 1 and names its site" do
        path = Path.join(Configs.dir(), unquote(site) <> ".json")

        if File.exists?(path) do
          assert Configs.check(unquote(site), File.read!(path)) == :ok
        end
      end
    end

    test "the directory holds nothing but the sites' documents" do
      for file <- File.ls!(Configs.dir()) do
        assert Path.rootname(file) in Data.Vocabulary.ext_sites() and
                 Path.extname(file) == ".json",
               "#{file} is not a site's document"
      end
    end
  end

  describe "validate/1" do
    test "a document of contract 1" do
      assert Configs.validate(@valid) == :ok
    end

    test "what is wrong, by its path" do
      doc =
        @valid
        |> put_in(["fields", "salary"], %{
          "on" => "job",
          "css" => ["x"],
          "read" => "text",
          "required" => true
        })
        |> put_in(["fields", "title", "css"], [])
        |> put_in(["fields", "title", "read"], "inner")
        |> put_in(["fields", "skills_text", "on"], "search")
        |> put_in(["pages", "listing"], %{"url" => ["/x"], "ready" => ["y"]})
        |> put_in(["identity", "read"], "text")
        |> put_in(["pages", "job", "url"], ["re:("])
        |> Map.put("contract", 2)
        |> Map.put("extra", true)

      assert {:error, problems} = Configs.validate(doc)

      for expected <- [
            "extra: is not in contract 1",
            "contract: is not 1",
            "pages.listing: is not a page kind",
            "pages.job.url[0]: is not a regular expression",
            "fields.salary: is not a field of §11.3",
            "fields.title.css: has 0, not 1–6",
            "fields.title.read: is not text, href, html, present or attr:<name>",
            "fields.skills_text.on: names no page of this document",
            "identity.read: is not href"
          ] do
        assert expected in problems, "#{expected} missing from #{inspect(problems)}"
      end
    end

    test "more than six selectors for a field" do
      doc = put_in(@valid, ["fields", "title", "css"], ~w(a b c d e f g))
      assert {:error, ["fields.title.css: has 7, not 1–6"]} = Configs.validate(doc)
    end

    test "a file that is not JSON, or names another site" do
      assert {:error, ["not JSON: " <> _]} = Configs.check("upwork", "{nope")

      assert {:error, ["site: is not linkedin"]} =
               Configs.check("linkedin", Jason.encode!(@valid))
    end
  end

  describe "publishing" do
    setup do
      dir = Path.join(System.tmp_dir!(), "aq-ext-config-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      %{dir: dir, system: Data.Scope.system()}
    end

    test "a changed file is the next version; the same file again is kept", c do
      live = Store.live_config(:upwork)

      body =
        @valid
        |> Map.put(
          "pages",
          Map.put(@valid["pages"], "search", %{
            "url" => ["/s#{System.unique_integer()}"],
            "ready" => ["ul"]
          })
        )
        |> Jason.encode!()

      File.write!(Path.join(c.dir, "upwork.json"), body)

      assert [{"linkedin", :missing}, {"upwork", {:published, version}}] =
               Configs.publish_files(c.system, c.dir, @now)

      assert version == ((live && live.version) || 0) + 1
      assert Store.live_config(:upwork).sha256 == Config.digest(body)

      assert [_, {"upwork", {:unchanged, ^version}}] =
               Configs.publish_files(c.system, c.dir, @now)
    end

    test "a file off the contract publishes nothing", c do
      File.write!(Path.join(c.dir, "linkedin.json"), ~s({"site":"linkedin","contract":1}))

      assert [{"linkedin", {:invalid, problems}}, {"upwork", :missing}] =
               Configs.publish_files(c.system, c.dir, @now)

      assert "pages: is missing" in problems
    end
  end

  describe "reading" do
    setup do
      c = board_cast_fixture()
      Map.merge(c, %{fiza: scope_for(c.fiza), dawud: scope_for(c.dawud)})
    end

    test "the live document is the highest version", c do
      config = config_fixture(:linkedin)
      assert {:ok, %{version: version, sha256: sha}} = Configs.live(c.fiza, "linkedin")
      assert {version, sha} == {config.version, config.sha256}
    end

    test "a site off the list is a field error", c do
      assert {:error, {:invalid, %{"site" => _}}} = Configs.live(c.fiza, "indeed")
      assert {:error, {:invalid, %{"site" => _}}} = Configs.live(c.fiza, nil)
    end

    test "the versions list is the system admin's, newest first", c do
      older = config_fixture(:upwork, published_at: ~U[2026-11-01 09:00:00.000000Z])
      newer = config_fixture(:upwork, published_at: ~U[2026-11-10 09:00:00.000000Z])

      assert {:ok, [first, second | _]} = Configs.list(c.dawud, %{"site" => "upwork"})
      assert {first.id, second.id} == {newer.id, older.id}
      assert Configs.list(c.fiza, %{"site" => "upwork"}) == {:error, :not_found}
    end
  end
end
