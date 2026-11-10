defmodule Data.OrganisationsTest do
  use Data.DataCase, async: true

  alias Data.Organisations
  alias Data.Organisations.Organisation

  test "the slug follows the name unless given, and is unique" do
    assert {:ok, org} = Organisations.create(%{name: "  Regbits BD  "})
    assert org.name == "Regbits BD" and org.slug == "regbits-bd"
    assert {:error, cs} = Organisations.create(%{name: "Regbits BD"})
    assert errors_on(cs).slug
    assert {:ok, other} = Organisations.create(%{name: "Regbits BD", slug: "regbits-2"})
    assert other.slug == "regbits-2"
    assert Organisation.slugify("Café & Co!") == "caf-co"
  end

  test "timezone, currency and country are checked" do
    assert {:error, cs} = Organisations.create(%{name: "X", timezone: "Mars/Olympus"})
    assert errors_on(cs).timezone
    assert {:error, cs} = Organisations.create(%{name: "X", currency_code: "dollars"})
    assert errors_on(cs).currency_code
    assert {:error, cs} = Organisations.create(%{name: "X", country_code: "Pakistan"})
    assert errors_on(cs).country_code

    assert {:ok, _org} =
             Organisations.create(%{
               name: "X",
               country_code: "PK",
               currency_code: "PKR",
               timezone: "Asia/Karachi"
             })
  end

  test "the_one is the oldest organisation" do
    first = organisation_fixture()
    _second = organisation_fixture()
    assert Organisations.the_one().id == first.id
  end

  test "settings: code defaults until written, every value 1–365" do
    org = organisation_fixture()
    assert Organisations.get_settings(org.id).purge_after_days == 90
    assert {:ok, row} = Organisations.put_settings(org.id, %{purge_after_days: 30})
    assert row.purge_after_days == 30 and row.warning_days == 7
    assert {:error, cs} = Organisations.put_settings(org.id, %{warning_days: 0})
    assert errors_on(cs).warning_days
    assert {:error, cs} = Organisations.put_settings(org.id, %{inactivity_days: 366})
    assert errors_on(cs).inactivity_days
  end

  test "admins: unique per organisation, counted, listed with their people" do
    org = organisation_fixture()
    admin = admin_fixture(org)
    assert Organisations.count_admins(org.id) == 1

    assert [%{user: %{person: %{display_name: "Test Person"}}}] =
             Organisations.list_admins(org.id)

    assert Organisations.admin_of(admin.id) == [org.id]

    assert {:error, _cs} =
             Organisations.grant_admin(%{
               organisation_id: org.id,
               user_id: admin.id,
               granted_at: DateTime.utc_now()
             })
  end
end
