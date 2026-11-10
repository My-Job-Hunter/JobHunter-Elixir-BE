defmodule ApiTeam.InvitationJSON do
  @moduledoc "The invitations' shapes (JH-01 §6.2), with their state and accept link."

  alias Core.Organisation.Invitations
  alias Data.Invitations.Invitation

  def index(%{invitations: invitations, now: now}) do
    Enum.map(invitations, &invitation(&1, now))
  end

  def show(%{invitation: invitation, now: now}), do: invitation(invitation, now)

  # `link` is the accept URL on the right app's origin: the console's for an
  # admin or a team member, the portal's for a customer (`accept_url` is
  # the same value under its older name).
  defp invitation(i, now) do
    link = Invitations.accept_url(i)

    %{
      id: i.id,
      kind: i.kind,
      code: i.code,
      email: i.email,
      invited_name: i.invited_name,
      team_id: i.team_id,
      team_name: i.team && i.team.name,
      role: i.role,
      customer_id: i.customer_id,
      customer_name: i.customer && i.customer.display_name,
      invited_by_user_id: i.invited_by_user_id,
      invited_by_name: Invitations.invited_by_name(i),
      state: Invitation.state(i, now),
      expires_at: i.expires_at,
      accepted_at: i.accepted_at,
      revoked_at: i.revoked_at,
      link: link,
      accept_url: link,
      inserted_at: i.inserted_at
    }
  end
end
