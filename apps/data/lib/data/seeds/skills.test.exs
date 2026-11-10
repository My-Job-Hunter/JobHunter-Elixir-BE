defmodule Data.Seeds.SkillsTest do
  use Data.DataCase, async: true

  alias Data.Customers.Skill
  alias Data.Seeds.Skills

  test "about 120 skills across the nine categories of §8, slugs unique" do
    all = Skills.all()
    assert length(all) >= 110 and length(all) <= 140

    assert all |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> Enum.sort() ==
             ~w(cloud data design frameworks languages management mobile product qa)

    slugs = Enum.map(all, fn {_category, name} -> Skill.slugify(name) end)
    assert slugs == Enum.uniq(slugs)
  end

  test "loads into every organisation, idempotent by slug" do
    org = organisation_fixture()
    skill_fixture(org, name: "Go", category: "languages")

    first = Skills.load_for(org.id)
    assert first.inserted == length(Skills.all()) - 1
    assert first.kept == 1
    assert Skills.load_for(org.id) == %{inserted: 0, kept: length(Skills.all())}
    assert length(Data.Skills.list(org.id)) == length(Skills.all())
  end
end
