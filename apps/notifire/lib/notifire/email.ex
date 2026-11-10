defmodule Notifire.Email do
  @moduledoc """
  What P1's three messages look like as mail: an invitation, a password
  reset, an email change. Plain text, deliberately: the useful part is the
  link, and the whole URL is visible so somebody can see where it goes.

  The sender and the app URLs are config (`:notifire`), read at send time:
  the envelope sender has to be a domain the provider is authorised for, and
  it differs per deploy.
  """

  import Swoosh.Email

  alias Data.Accounts.UserToken
  alias Data.Invitations.Invitation

  @doc "The invitation (JH-01 §3): who invited you, to what, and the link."
  @spec invitation(Invitation.t()) :: Swoosh.Email.t()
  def invitation(%Invitation{} = invitation) do
    who = inviter(invitation)
    org = invitation.organisation.name

    new()
    |> to(recipient(invitation.invited_name, invitation.email))
    |> from(sender())
    |> subject("#{who} invited you to #{org}")
    |> text_body("""
    #{who} invited you to #{org} #{as_what(invitation)}.

    Open this link to accept:

    #{accept_url(invitation)}

    The link works once and expires on #{Calendar.strftime(invitation.expires_at, "%-d %b")}.
    """)
  end

  defp as_what(%Invitation{kind: :admin}), do: "as an admin"
  defp as_what(%Invitation{kind: :team_member} = i), do: "as a team #{i.role} of #{i.team.name}"
  defp as_what(%Invitation{kind: :customer}), do: "as a customer"

  defp inviter(%Invitation{invited_by_user: %{person: %{display_name: name}}}), do: name
  defp inviter(%Invitation{organisation: %{name: name}}), do: name

  @doc "The password reset link: the only mail that carries a credential."
  @spec password_reset(UserToken.t(), String.t()) :: Swoosh.Email.t()
  def password_reset(%UserToken{user: user}, token) do
    new()
    |> to(recipient(user.person.display_name, user.email))
    |> from(sender())
    |> subject("Reset your Job Hunter password")
    |> text_body("""
    Somebody asked to reset the password for this Job Hunter account.

    Open this link to choose a new one:

    #{console_url()}/reset-password?token=#{URI.encode(token)}

    The link works once and expires in an hour.

    If this was not you, you can ignore this: nothing has changed, and your
    current password still works.
    """)
  end

  @doc """
  Confirming a new address. **Addressed to the new address, never to
  `user.email`**: the link proves the new mailbox, so it must arrive there.
  """
  @spec email_change(UserToken.t(), String.t()) :: Swoosh.Email.t()
  def email_change(%UserToken{user: user} = row, token) do
    new()
    |> to(recipient(user.person.display_name, UserToken.address(row)))
    |> from(sender())
    |> subject("Confirm your new email for Job Hunter")
    |> text_body("""
    Someone asked to move a Job Hunter account to this address.

    Until this link is followed, nothing has changed and the old address is
    still the login:

    #{console_url()}/account/confirm-email?token=#{URI.encode(token)}

    The link lasts a day. If this was not you, do not follow it.
    """)
  end

  defp recipient(nil, email), do: email
  defp recipient(name, email), do: {name, email}

  defp sender do
    {Application.get_env(:notifire, :from_name, "Job Hunter"),
     Application.get_env(:notifire, :from_email, "hello@jobhunter.local")}
  end

  defp accept_url(%Invitation{kind: kind, code: code}) do
    base = if kind == :customer, do: portal_url(), else: console_url()
    "#{base}/invite/#{code}"
  end

  defp console_url, do: Keyword.get(urls(), :console, "http://localhost:5800")
  defp portal_url, do: Keyword.get(urls(), :portal, "http://localhost:5801")
  defp urls, do: Application.get_env(:notifire, :app_urls, [])
end
