defmodule Core.Leads.Guard do
  @moduledoc """
  The duplicate guard, the lead half (AQ-04A §6, QP4a-9): **one rule, one
  home.** The check asks it with a `profile_id`, and so do `POST /leads` and
  every verb that applies, inside their transactions; P5's extension and
  P9's email will ask the same function.

  **It works by posting, not by row.** A posting is a canonical key: the
  guard reads every lead of the organisation, **in every team**, whose job
  has that key or had it merged in (`job_merges`), whether or not the
  caller may see them.

  | Answer | When |
  |---|---|
  | `saved` | this profile has a lead in To do, in this team |
  | `refused` | this profile has a lead past To do (archived or not), in this team |
  | `refused` (tombstone) | no lead left, but this profile's purged lead on the posting was applied (`lead_fingerprints`, AQ-04B §7.2): `existing: {applied_at, team, purged: true}` |
  | `elsewhere` | this profile has a lead on the posting in another team, in any state |
  | `warn` | another profile of the same customer has one, in any team, or a tombstone (`purged: true` in `same_customer`) |
  | `shared` | only other customers' leads are on the posting |
  | `free` | none of the above |

  A lead in another team is named only as "another team": no id, state,
  stage or person. A lead in this team the caller may not see is named
  only as "another member": no id, state or stage, and no `by`.

  `lock!/3` takes the transaction-scoped advisory lock on (organisation,
  canonical key, profile) that keeps two teams racing apart; `refuse/4` is
  what a write asks under it, answering `{:duplicate_application, %{existing,
  message}}` for the 409. For a tombstone the words are "Already applied
  as “Golang” on 16 Oct; that lead was cleared after 180 quiet days.", and
  `again: reason` (*Apply again…*, a new lead) lets the write through.
  """

  alias Core.Access
  alias Core.Leads.Words
  alias Core.Retention.Policy
  alias Core.Tasks.Person
  alias Data.Leads, as: Store
  alias Data.Retention, as: Tombstones
  alias Data.Scope

  @doc """
  The guard's answer for `profile` on the posting `key`, seen from `team_id`:
  `%{answer, existing, same_customer, lead}` — `existing` as §8.3's check
  shape names it (or `nil`), `lead` the profile's own lead struct (or `nil`).
  `opts[:except]` leaves a lead out (the one an apply moves).
  """
  @spec assess(Scope.t(), String.t(), binary(), map(), keyword()) :: map()
  def assess(%Scope{} = scope, key, team_id, profile, opts \\ []) do
    org_id = Scope.organisation_id(scope)
    except = opts[:except]
    keys = Store.posting_keys(org_id, key)

    leads =
      org_id
      |> Store.on_posting(keys)
      |> Enum.reject(&(&1.id == except))

    {mine, others} = Enum.split_with(leads, &(&1.profile_id == profile.id))
    same = Enum.filter(others, &(&1.profile.customer_id == profile.customer_id))
    here = Enum.find(mine, &(&1.job.team_id == team_id))
    lead = here || List.first(mine)

    # AQ-04B §7.2: the tombstones of purged leads that were applied.
    {tomb_mine, tomb_same} =
      org_id
      |> Tombstones.fingerprints_on(keys)
      |> Enum.filter(&(&1.applied_on && &1.customer_id == profile.customer_id))
      |> Enum.split_with(&(&1.profile_id == profile.id))

    tomb = if lead, do: nil, else: List.last(tomb_mine)
    zone = Core.Tasks.zone(scope)

    %{
      answer: answer(here, mine, same, others, tomb, tomb_same),
      existing:
        (lead && existing(scope, lead, team_id, stage: true)) ||
          (tomb && purged(tomb, team_id, zone)),
      same_customer:
        Enum.map(same, &same_customer(scope, &1, team_id)) ++
          Enum.map(tomb_same, &purged_same(&1, team_id, zone)),
      lead: lead,
      fingerprint: tomb
    }
  end

  defp answer(%{state: :todo}, _mine, _same, _others, _tomb, _tomb_same), do: "saved"
  defp answer(%{}, _mine, _same, _others, _tomb, _tomb_same), do: "refused"
  defp answer(nil, [_ | _], _same, _others, _tomb, _tomb_same), do: "elsewhere"
  defp answer(nil, [], _same, _others, %{}, _tomb_same), do: "refused"
  defp answer(nil, [], [_ | _], _others, nil, _tomb_same), do: "warn"
  defp answer(nil, [], [], _others, nil, [_ | _]), do: "warn"
  defp answer(nil, [], [], [_ | _], nil, []), do: "shared"
  defp answer(nil, [], [], [], nil, []), do: "free"

  @doc "The advisory lock on (organisation, key, profile), for the transaction it runs in."
  @spec lock!(Scope.t(), String.t(), binary()) :: :ok
  def lock!(%Scope{} = scope, key, profile_id),
    do: Store.lock(Scope.organisation_id(scope), key, profile_id)

  @doc """
  Inside a write's transaction, under `lock!/3`: `:ok` when `profile` has no
  lead on the posting (but `opts[:except]`), else the 409's reason.
  """
  @spec refuse(Scope.t(), String.t(), binary(), map(), keyword()) :: :ok | {:error, term()}
  def refuse(%Scope{} = scope, key, team_id, profile, opts \\ []) do
    case assess(scope, key, team_id, profile, opts) do
      %{lead: nil, fingerprint: nil} ->
        :ok

      %{lead: nil, fingerprint: tomb} ->
        if opts[:again], do: :ok, else: {:error, tombstone(scope, tomb, team_id, profile)}

      %{lead: lead} ->
        {:error, duplicate(scope, lead, team_id, profile)}
    end
  end

  @doc """
  The 409 `duplicate_application` for a purged pair (AQ-04B §7.2): "Already
  applied as “Golang” on 16 Oct; that lead was cleared after 180 quiet
  days.", `existing: {applied_at, team, purged: true}`.
  """
  @spec tombstone(Scope.t(), map(), binary(), map()) :: {:duplicate_application, map()}
  def tombstone(%Scope{} = scope, tomb, team_id, profile) do
    settings = Data.Organisations.get_settings(Scope.organisation_id(scope))
    zone = Core.Tasks.zone(scope)
    existing = purged(tomb, team_id, zone)
    days = settings.inactivity_days + settings.purge_after_days

    {:duplicate_application,
     %{
       existing: existing,
       message:
         "Already applied as #{Words.quoted(profile.title)} on " <>
           "#{Calendar.strftime(tomb.applied_on, "%-d %b")}; " <>
           "that lead was cleared after #{days} quiet days."
     }}
  end

  # A tombstone as the check and the 409 name it: the day applied (its
  # start, in the organisation's zone), the team, and `purged`.
  defp purged(tomb, team_id, zone) do
    %{
      applied_at: Policy.start_of(tomb.applied_on, zone),
      team: if(tomb.team_id == team_id, do: "this", else: "another"),
      purged: true
    }
  end

  defp purged_same(tomb, team_id, zone) do
    %{
      profile: %{id: tomb.profile.id, title: tomb.profile.title},
      state: nil,
      applied_at: Policy.start_of(tomb.applied_on, zone),
      team: if(tomb.team_id == team_id, do: "this", else: "another"),
      purged: true
    }
  end

  @doc "The 409 `duplicate_application` for `profile`'s `lead`, as `scope` may know it."
  @spec duplicate(Scope.t(), map(), binary(), map()) :: {:duplicate_application, map()}
  def duplicate(%Scope{} = scope, lead, team_id, profile) do
    existing = existing(scope, lead, team_id, stage: false)

    {:duplicate_application,
     %{existing: existing, message: words(scope, profile, lead, existing)}}
  end

  # §8.3: `{lead_id?, state?, stage?, applied_at, by?, team}`; the keys the
  # caller may not know are left out.
  defp existing(scope, lead, team_id, opts) do
    cond do
      lead.job.team_id != team_id ->
        %{applied_at: lead.applied_at, team: "another"}

      Access.can?(scope, :read, {:lead, Core.Leads.subject(lead)}) ->
        %{
          lead_id: lead.id,
          state: lead.state,
          applied_at: lead.applied_at,
          by: Person.view(by(lead)),
          team: "this"
        }
        |> then(&if(opts[:stage], do: Map.put(&1, :stage, stage(lead)), else: &1))

      true ->
        %{applied_at: lead.applied_at, team: "this"}
    end
  end

  defp same_customer(scope, lead, team_id) do
    here? = lead.job.team_id == team_id
    visible? = here? and Access.can?(scope, :read, {:lead, Core.Leads.subject(lead)})

    %{
      profile: %{id: lead.profile.id, title: lead.profile.title},
      state: lead.state,
      applied_at: lead.applied_at,
      team: if(here?, do: "this", else: "another")
    }
    |> then(&if(visible?, do: Map.put(&1, :by, Person.view(by(lead))), else: &1))
  end

  defp stage(%{stage: nil}), do: nil
  defp stage(%{stage: s}), do: %{key: s.key, name: s.name}

  # Who the banner names: whoever applied, else whoever saved it, else its owner.
  defp by(lead), do: lead.applied_by_user || lead.created_by_user || lead.owner_user

  # §11.3's refusal: "*Golang* already has a lead on this job: applied by
  # Fiza, 12 Oct." In another team: "…in another team, applied 12 Oct."
  defp words(scope, profile, lead, existing) do
    zone = Core.Tasks.zone(scope)
    title = Words.quoted(profile.title)

    {verb, at} =
      if lead.applied_at, do: {"applied", lead.applied_at}, else: {"saved", lead.inserted_at}

    day = Words.day(at, zone)

    case existing do
      %{team: "another"} ->
        "#{title} already has a lead on this job in another team, #{verb} #{day}."

      %{by: %{name: name}} ->
        "#{title} already has a lead on this job: #{verb} by #{first(name)}, #{day}."

      _hidden ->
        "#{title} already has a lead on this job: #{verb} by another member, #{day}."
    end
  end

  defp first(name), do: name |> String.split(" ", trim: true) |> List.first() || name
end
