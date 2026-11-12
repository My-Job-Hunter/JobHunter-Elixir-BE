defmodule ApiShared.CustomersJSON do
  @moduledoc """
  The shapes of customers, profiles, channels, documents, notes and skills
  (AQ-01 §4.3, §6.2, §6.3), **shared by the console and the portal** so the
  two apps read one field list. Fields are listed one by one — a view that
  serialises a whole struct leaks the next column somebody adds.

  Payload names the frontend relies on: a customer's `teams: [{id, name}]`,
  `profiles: [{id, title}]`, `owners: [{user_id, display_name}]`,
  `last_signed_in_at`; a profile's `skills: [{skill_id, name, level, years}]`,
  `owners`, `channel_ids`, `default_document_id`; a channel's `profile_ids`;
  a document's `media: {id, url, byte_count, content_type, original_filename}`
  (null for a link), `is_default`, `version_no`, `supersedes_document_id`.
  """

  alias Core.Media
  alias Data.Customers.{Customer, Document, Profile}

  @profile_columns Profile.pitch_fields() ++ Profile.facts_fields()

  @doc "A customer with teams, profiles (titles), owners and the login's last sign-in."
  def customer(%Customer{} = c) do
    profiles = Enum.reject(c.profiles, & &1.archived_at)

    %{
      id: c.id,
      display_name: c.display_name,
      email: c.email,
      phone_e164: c.phone_e164,
      timezone: c.timezone,
      location_text: c.location_text,
      country_code: c.country_code,
      status: c.status,
      started_on: c.started_on,
      ended_on: c.ended_on,
      archived_at: c.archived_at,
      user_id: c.user_id,
      last_signed_in_at: c.user && c.user.last_signed_in_at,
      teams: for(link <- c.customer_teams, do: %{id: link.team.id, name: link.team.name}),
      profiles: for(p <- profiles, do: %{id: p.id, title: p.title}),
      owners: profiles |> Enum.flat_map(& &1.profile_members) |> owners(),
      inserted_at: c.inserted_at,
      updated_at: c.updated_at
    }
  end

  @doc "A profile: every §4.3 column by name, plus skills, owners, channel ids and the default document."
  def profile(%Profile{} = p) do
    @profile_columns
    |> Map.new(&{&1, Map.get(p, &1)})
    |> Map.merge(%{
      id: p.id,
      customer_id: p.customer_id,
      archived_at: p.archived_at,
      skills:
        for s <- p.profile_skills do
          %{
            skill_id: s.skill_id,
            name: s.skill.name,
            slug: s.skill.slug,
            category: s.skill.category,
            level: s.level,
            years: s.years
          }
        end,
      owners: owners(p.profile_members),
      channel_ids: Enum.map(p.profile_channels, & &1.channel_id),
      default_document_id: Profile.default_document_id(p),
      inserted_at: p.inserted_at,
      updated_at: p.updated_at
    })
  end

  @doc "A channel: the §4.3 columns and the profiles linked to it. Never a credential."
  def channel(ch) do
    %{
      id: ch.id,
      customer_id: ch.customer_id,
      kind: ch.kind,
      label: ch.label,
      handle: ch.handle,
      handle_normalized: ch.handle_normalized,
      operated_by: ch.operated_by,
      listens_via: ch.listens_via,
      inbound_address: ch.inbound_address,
      last_seen_at: ch.last_seen_at,
      status: ch.status,
      archived_at: ch.archived_at,
      profile_ids: Enum.map(ch.profile_channels, & &1.profile_id),
      inserted_at: ch.inserted_at,
      updated_at: ch.updated_at
    }
  end

  @doc "A document: its version chain, whether it is the profile's default, and its file or link."
  def document(%Document{} = d) do
    %{
      id: d.id,
      profile_id: d.profile_id,
      kind: d.kind,
      label: d.label,
      version_no: d.version_no,
      supersedes_document_id: d.supersedes_document_id,
      url: d.url,
      is_default: Profile.default_document_id(d.profile) == d.id,
      media: media(Document.media(d)),
      archived_at: d.archived_at,
      inserted_at: d.inserted_at,
      updated_at: d.updated_at
    }
  end

  @doc "A staff-only note with its author's name."
  def note(n) do
    %{
      id: n.id,
      customer_id: n.customer_id,
      author_user_id: n.author_user_id,
      author_name: n.author_user && n.author_user.person.display_name,
      body_md: n.body_md,
      edited_at: n.edited_at,
      deleted_at: n.deleted_at,
      inserted_at: n.inserted_at,
      updated_at: n.updated_at
    }
  end

  @doc "One skill of the vocabulary."
  def skill(s) do
    %{id: s.id, name: s.name, slug: s.slug, category: s.category, archived_at: s.archived_at}
  end

  defp owners(members) do
    members
    |> Enum.map(&%{user_id: &1.user_id, display_name: &1.user.person.display_name})
    |> Enum.uniq_by(& &1.user_id)
    |> Enum.sort_by(& &1.display_name)
  end

  defp media(nil), do: nil

  defp media(m) do
    %{
      id: m.id,
      url: Media.link(m.id),
      byte_count: m.byte_count,
      content_type: m.content_type,
      original_filename: m.original_filename,
      page_count: m.page_count,
      uploaded_at: m.uploaded_at
    }
  end
end
