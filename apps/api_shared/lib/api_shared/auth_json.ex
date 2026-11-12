defmodule ApiShared.AuthJSON do
  @moduledoc """
  The shapes the auth routes answer with (AQ-01 §6.1): snake_case, no
  envelope, fields listed one by one — a view that serialises a whole struct
  leaks the next field somebody adds.
  """

  alias ApiShared.MeJSON

  def session(%{tokens: tokens, user: user} = assigns) do
    base = %{
      access_token: tokens.access_token,
      refresh_token: tokens.refresh_token,
      user: MeJSON.user(user)
    }

    case Map.fetch(assigns, :landing) do
      {:ok, landing} -> Map.put(base, :landing, landing)
      :error -> base
    end
  end

  def tokens(%{tokens: tokens}),
    do: %{access_token: tokens.access_token, refresh_token: tokens.refresh_token}

  def invitation(%{invitation: i}) do
    %{
      kind: i.kind,
      organisation_name: i.organisation_name,
      team_name: i.team_name,
      role: i.role,
      customer_name: i.customer_name,
      invited_name: i.invited_name,
      invited_by: i.invited_by,
      invited_by_name: i.invited_by,
      email: i.email,
      expires_at: i.expires_at,
      has_account: i.has_account
    }
  end
end
