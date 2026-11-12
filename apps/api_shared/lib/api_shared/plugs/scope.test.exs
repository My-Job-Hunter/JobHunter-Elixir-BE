defmodule ApiShared.Plugs.ScopeTest do
  use ApiShared.SharedCase, async: true

  alias ApiShared.Plugs.Scope, as: ScopePlug

  test "builds the scope from the current user with the request id" do
    org = organisation_fixture()
    admin = admin_fixture(org)

    conn =
      :get
      |> build("/v1/me")
      |> assign(:current_user, admin)
      |> put_resp_header("x-request-id", "req-1")
      |> ScopePlug.call([])

    assert %Data.Scope{} = scope = conn.assigns.scope
    assert scope.user.id == admin.id
    assert scope.organisation.id == org.id
    assert scope.roles.admin?
    assert scope.request_id == "req-1"
    assert scope.via == :web
  end

  test "on /ext the scope is via: :extension (AQ-05 §11.4)" do
    org = organisation_fixture()
    admin = admin_fixture(org)

    conn =
      :get
      |> build("/v1/me")
      |> assign(:current_user, admin)
      |> assign(:app, "ext")
      |> ScopePlug.call([])

    assert conn.assigns.scope.via == :extension
  end

  test "leaves a conn with nobody alone" do
    conn = build(:get, "/v1/me") |> ScopePlug.call([])
    refute Map.has_key?(conn.assigns, :scope)
  end
end
