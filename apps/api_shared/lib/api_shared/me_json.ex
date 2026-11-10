defmodule ApiShared.MeJSON do
  @moduledoc """
  `/me` as JH-01 §6.1 spells it:

      {user: {id, email, person: {display_name, given_name, family_name, photo_url, timezone, locale_code}},
       roles: {admin, teams: [{team_id, name, role}], customer_id},
       settings, organisation: {id, name, timezone, currency_code}}
  """

  alias Core.Accounts.Device
  alias Core.Media
  alias Data.Accounts
  alias Data.Accounts.Person

  def me(%{me: me}) do
    %{
      user: user(me.user),
      roles: me.roles,
      settings: settings_json(me.settings),
      organisation: organisation(me.organisation)
    }
  end

  def settings(%{settings: settings}), do: settings_json(settings)

  # `device` is the "Chrome on macOS" line read from the user agent the
  # sign-in stored in the token's claims; `current` marks this session.
  def sessions(%{sessions: sessions}) do
    for s <- sessions do
      %{
        sid: s.sid,
        device: Device.describe(s.device),
        app: s.device["app"],
        signed_in_at: s.signed_in_at,
        expires_at: s.expires_at,
        current: s.is_current,
        is_current: s.is_current
      }
    end
  end

  @doc "One account, as every shared route renders it."
  def user(user) do
    user = Accounts.with_person(user)
    person = user.person

    %{
      id: user.id,
      email: user.email,
      email_confirmed_at: user.email_confirmed_at,
      has_password: not is_nil(user.hashed_password),
      last_signed_in_at: user.last_signed_in_at,
      suspended_at: user.suspended_at,
      person: %{
        display_name: person.display_name,
        given_name: person.given_name,
        family_name: person.family_name,
        photo_url: photo_url(Person.photo_media_id(person)),
        timezone: person.timezone,
        locale_code: person.locale_code
      }
    }
  end

  @doc "The organisation, as `/me` and `/org` render it."
  def organisation(nil), do: nil

  def organisation(organisation) do
    %{
      id: organisation.id,
      name: organisation.name,
      slug: organisation.slug,
      country_code: organisation.country_code,
      timezone: organisation.timezone,
      currency_code: organisation.currency_code
    }
  end

  defp photo_url(nil), do: nil
  defp photo_url(media_id), do: Media.link(media_id)

  defp settings_json(s) do
    %{
      theme: s.theme,
      quiet_hours_start: s.quiet_hours_start,
      quiet_hours_end: s.quiet_hours_end,
      digest_time: s.digest_time,
      digest_on: s.digest_on
    }
  end
end
