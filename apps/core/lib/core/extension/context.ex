defmodule Core.Extension.Context do
  @moduledoc """
  The acting profile and the team (AQ-05 §8, PLAN §12.4, QP5-7…9):
  `GET /ext/v1/context?site&identity` — who the page's signed-in account
  is, and the profiles the person may act for.

  **The identity** is the profile link the extension read off the page,
  turned into `Utils.ChannelKey`'s key for the site:

  | `identity.state` | When |
  |---|---|
  | `channel` | the key is a live channel the person may read; its `last_seen_at` moves |
  | `unknown` | a link was read, and it is no channel the person may read (their own account, an agency manager's, nobody's) |
  | `none` | nothing was read yet (LinkedIn before a press; signed out) |

  **The profiles** are what `POST /leads` would accept: live profiles of
  customers who are neither paused nor ended, that the person reads,
  each with **the person's teams that serve its customer** (the system
  admin: every serving team) — a profile no such team serves is left out.
  `matched` marks the profiles linked to the identity's channel, which
  come first. **`pick`** is there when the channel names exactly one of
  them: `{profile_id, team_id}`, `team_id` only when that profile has one
  team. A channel of another customer than the acting profile's is the
  panel's red line; *I applied* there is refused at the write (409
  `identity_mismatch`, `Core.Ingest.Extension`).
  """

  alias Core.Access
  alias Core.Tasks.Person
  alias Data.Accounts
  alias Data.Channels
  alias Data.Customers.Profile
  alias Data.Documents
  alias Data.Profiles
  alias Data.Scope
  alias Data.Teams
  alias Data.Vocabulary
  alias Utils.ChannelKey

  @doc "`GET /ext/v1/context?site&identity`: §11.3's `context`."
  @spec get(Scope.t(), map(), DateTime.t()) :: {:ok, map()} | {:error, term()}
  def get(%Scope{} = scope, params, %DateTime{} = now) do
    with :ok <- Access.why_not(scope, :use, :extension),
         {:ok, site} <- site(params["site"]) do
      identity = identity(scope, site, params["identity"], now)
      profiles = profiles(scope, identity.channel)

      {:ok,
       %{
         me: %{
           person: Person.view(Accounts.with_person(scope.user)),
           is_admin: Scope.admin?(scope)
         },
         identity: identity,
         profiles: profiles,
         pick: pick(profiles)
       }}
    end
  end

  defp site(site) do
    if is_binary(site) and site in Vocabulary.ext_sites(),
      do: {:ok, site},
      else:
        {:error,
         {:invalid, %{"site" => ["is one of #{Enum.join(Vocabulary.ext_sites(), ", ")}"]}}}
  end

  @doc """
  The channel the page's account is, as `scope` may know it, or `nil`: the
  live channel whose identity key is the link's, when the caller reads it.
  What the context names and what the extension's applied refuses on.
  """
  @spec channel(Scope.t(), String.t() | atom(), term()) ::
          {:channel, map()} | {:hidden, map()} | :unknown | :none
  def channel(%Scope{} = scope, site, link) do
    case Utils.presence(if(is_binary(link), do: link, else: nil)) do
      nil -> :none
      link -> scope |> by_key(ChannelKey.key(site, link)) |> seen_as(scope)
    end
  end

  defp by_key(_scope, nil), do: nil
  defp by_key(scope, key), do: Channels.by_identity(Scope.organisation_id(scope), key)

  defp seen_as(nil, _scope), do: :unknown

  defp seen_as(channel, scope) do
    if Access.can?(scope, :read, {:channel, channel}),
      do: {:channel, channel},
      else: {:hidden, channel}
  end

  defp identity(scope, site, link, now) do
    case channel(scope, site, link) do
      {:channel, channel} ->
        :ok = Channels.seen(channel, now)
        %{state: "channel", channel: channel}

      :none ->
        %{state: "none", channel: nil}

      _unknown_or_hidden ->
        %{state: "unknown", channel: nil}
    end
  end

  # ── The profiles ────────────────────────────────────────────────────────────

  @doc """
  The profiles `scope` may act for, with their serving teams (the caller's;
  every one for the system admin), by customer then title.
  """
  @spec actable(Scope.t()) :: [map()]
  def actable(%Scope{} = scope) do
    live_teams = live_teams(scope)

    scope
    |> Scope.organisation_id()
    |> Profiles.live_in_organisation()
    |> Enum.filter(
      &(&1.customer.status not in [:paused, :ended] and Access.can?(scope, :read, {:profile, &1}))
    )
    |> Enum.map(fn profile ->
      teams =
        for id <- profile.customer.team_ids,
            team = live_teams[id],
            Scope.admin?(scope) or Scope.team_role(scope, id),
            do: team

      {profile, Enum.sort_by(teams, & &1.name)}
    end)
    |> Enum.reject(fn {_profile, teams} -> teams == [] end)
  end

  defp profiles(scope, channel) do
    linked = if channel, do: Enum.map(channel.profile_channels, & &1.profile_id), else: []

    scope
    |> actable()
    |> Enum.map(fn {profile, teams} ->
      %{
        id: profile.id,
        title: profile.title,
        customer: %{id: profile.customer.id, display_name: profile.customer.display_name},
        teams: Enum.map(teams, &%{id: &1.id, name: &1.name}),
        cvs: cvs(profile),
        matched: profile.id in linked
      }
    end)
    |> Enum.sort_by(&if(&1.matched, do: 0, else: 1))
  end

  defp live_teams(scope) do
    scope
    |> Scope.organisation_id()
    |> Teams.list([])
    |> Map.new(&{&1.id, &1})
  end

  defp cvs(profile) do
    default = Profile.default_document_id(profile)

    for doc <- Documents.list(profile.id), doc.kind == :cv do
      %{id: doc.id, label: doc.label, version: doc.version_no, is_default: doc.id == default}
    end
  end

  defp pick(profiles) do
    case Enum.filter(profiles, & &1.matched) do
      [%{id: id, teams: [%{id: team_id}]}] -> %{profile_id: id, team_id: team_id}
      [%{id: id}] -> %{profile_id: id, team_id: nil}
      _none_or_several -> nil
    end
  end
end
