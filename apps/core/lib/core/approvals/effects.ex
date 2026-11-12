defmodule Core.Approvals.Effects do
  @moduledoc """
  What approval does (AQ-07 §7, QP7-10), **through the existing verbs, in
  the decision's transaction**:

  | Kind | On approved | Effect |
  |---|---|---|
  | `reply` | *Ready to send*; *Recorded as sent* writes the message (`Core.Approvals.Act.sent/3`) | `ready` |
  | `proposal` | the bid and Connects stored on the lead (P4a's `edit`), ready to send | `ready` |
  | `cv_for_job` | the lead's CV set (P4a's `cv`; its `cv_set` says who approved it) | `applied` |
  | `cover_letter` | the lead's `cover_letter_md` set (P4a's `edit`), ready to send | `ready` |
  | `rate` | the lead's expectation set (P4a's `edit`) | `applied` |
  | `asset` | its files shown on the lead (the Approvals tab) | `applied` |
  | `profile_change` | the proposed pitch and skills applied (P1's pitch and skills writes) | `applied` |
  | `other` | nothing automatic | `none` |

  **Whose act it is** (§7): the decision is the reviewer's; the effect is
  the approval's, made **on the requester's behalf** — their scope (as
  `via: :system`; the system's when they are gone), authorised by the
  approval rather than by `Core.Access`, so a member's approved pitch
  applies though they still can't edit it (QP7-15).

  **When it can't apply** (QP7-11) — the lead archived, the CV deleted, a
  title another profile holds — the decision stands and the effect is
  `failed` with the reason. Every reason is checked **before** a write,
  because a write refused inside the decision's transaction would take the
  decision down with it.
  """

  alias Core.Access.Grants
  alias Core.Approvals.Sheet
  alias Core.Customers.Profiles
  alias Core.Leads.Change
  alias Data.Accounts
  alias Data.Customers.Profile
  alias Data.Leads.Lead
  alias Data.Scope

  @doc """
  Runs the effect of `approval`, just approved by `by` (words: "Tanweer",
  or "automatically"), at `now`. Answers `{effect, note}`: `:none`,
  `:ready`, `:applied`, or `:failed` with the reason.
  """
  @spec run(map(), String.t(), DateTime.t()) :: {atom(), String.t() | nil}
  def run(approval, by, %DateTime{} = now) do
    version = Sheet.current(approval)

    case check(approval, version) do
      :ok -> apply_kind(approval.approval_kind, approval, version, on_behalf(approval), by, now)
      {:failed, reason} -> {:failed, reason}
    end
  end

  # ── Whether it can apply ────────────────────────────────────────────────────

  # A reply, an asset or anything else writes nothing, so nothing stops it.
  defp check(%{approval_kind: kind}, _version) when kind in [:reply, :asset, :other], do: :ok
  defp check(%{approval_kind: :profile_change} = a, version), do: profile_check(a, version)
  defp check(%{approval_kind: :cover_letter, lead: nil}, _version), do: :ok

  defp check(a, version) do
    lead = Data.Leads.reload(a.lead)

    cond do
      lead.archived_at -> {:failed, "the lead is archived"}
      a.approval_kind == :cv_for_job -> cv_check(lead, version)
      true -> facts_check(lead, facts(a, version))
    end
  end

  defp cv_check(lead, version) do
    case version.proposed_document_id && Data.Documents.get(version.proposed_document_id) do
      nil -> {:failed, "the CV was deleted"}
      %{archived_at: %DateTime{}} -> {:failed, "the CV was deleted"}
      %{profile_id: id} when id != lead.profile_id -> {:failed, "the CV isn't this profile's"}
      _live -> :ok
    end
  end

  defp facts_check(lead, attrs) do
    atoms = Map.new(attrs, fn {k, v} -> {String.to_existing_atom(k), v} end)

    if Lead.changeset(lead, atoms).valid?,
      do: :ok,
      else: {:failed, "the lead won't take these values"}
  end

  defp profile_check(a, version) do
    profile = Data.Profiles.get(a.profile_id)
    title = version.proposed_title

    cond do
      is_nil(profile) or profile.archived_at ->
        {:failed, "the profile is archived"}

      title && title != profile.title && title_taken?(profile, title) ->
        {:failed, "another of #{profile.customer.display_name}'s profiles is called #{title}"}

      not Profile.pitch_changeset(profile, pitch(version)).valid? ->
        {:failed, "the profile won't take this pitch"}

      not skills_known?(profile, version.proposed_skill_ids) ->
        {:failed, "a proposed skill is no longer in the list"}

      true ->
        :ok
    end
  end

  defp title_taken?(profile, title),
    do:
      Enum.any?(
        Data.Profiles.list(profile.customer_id),
        &(&1.id != profile.id and &1.title == title)
      )

  defp skills_known?(_profile, nil), do: true

  defp skills_known?(profile, ids) do
    known = profile.customer.organisation_id |> Data.Skills.list(ids: ids) |> Enum.map(& &1.id)
    Enum.all?(ids, &(&1 in known))
  end

  # ── Applying it ─────────────────────────────────────────────────────────────

  defp apply_kind(:reply, _a, _v, _scope, _by, _now), do: {:ready, nil}
  defp apply_kind(:asset, _a, _v, _scope, _by, _now), do: {:applied, nil}
  defp apply_kind(:other, _a, _v, _scope, _by, _now), do: {:none, nil}

  defp apply_kind(:cv_for_job, a, version, scope, by, now) do
    lead = Data.Leads.reload(a.lead)

    if lead.document_id != version.proposed_document_id do
      {:ok, _lead} =
        Change.set_cv(scope, lead, version.proposed_document_id, now, %{note: "Approved by #{by}"})
    end

    {:applied, nil}
  end

  defp apply_kind(kind, a, version, scope, _by, now)
       when kind in [:proposal, :rate, :cover_letter] do
    attrs = facts(a, version)

    if attrs != %{} do
      {:ok, _lead} = Change.save_facts(scope, Data.Leads.reload(a.lead), attrs, now)
    end

    {if(kind == :rate, do: :applied, else: :ready), nil}
  end

  defp apply_kind(:profile_change, a, version, scope, _by, _now) do
    profile = Data.Profiles.get(a.profile_id)
    pitch = pitch(version)

    if pitch != %{} do
      {:ok, _profile} = Profiles.write_pitch(scope, profile, pitch)
    end

    if version.proposed_skill_ids do
      {:ok, _profile} =
        Profiles.write_skills(
          scope,
          Data.Profiles.get(a.profile_id),
          skill_rows(profile, version)
        )
    end

    {:applied, nil}
  end

  # The lead's facts a kind sets, as P4a's `edit` takes them.
  defp facts(%{approval_kind: :proposal}, v) do
    bid =
      if v.proposed_bid_minor,
        do: %{
          "bid_minor" => v.proposed_bid_minor,
          "bid_currency" => v.proposed_bid_currency,
          "bid_period" => v.proposed_bid_period
        },
        else: %{}

    if v.proposed_connects, do: Map.put(bid, "connects_spent", v.proposed_connects), else: bid
  end

  defp facts(%{approval_kind: :rate}, v) do
    %{
      "expectation_minor" => v.proposed_expectation_minor,
      "expectation_currency" => v.proposed_expectation_currency,
      "expectation_period" => v.proposed_expectation_period
    }
  end

  defp facts(%{approval_kind: :cover_letter, lead: %{}}, v), do: %{"cover_letter_md" => v.body_md}
  defp facts(_a, _v), do: %{}

  defp pitch(v) do
    [
      {"title", v.proposed_title},
      {"headline", v.proposed_headline},
      {"summary_md", v.proposed_summary}
    ]
    |> Enum.reject(fn {_k, value} -> is_nil(value) end)
    |> Map.new()
  end

  # Skills kept keep their level and years; a new one is `working`.
  defp skill_rows(profile, version) do
    held = Map.new(profile.profile_skills, &{&1.skill_id, &1})

    Enum.map(version.proposed_skill_ids, fn id ->
      case held[id] do
        nil -> %{"skill_id" => id, "level" => "working"}
        s -> %{"skill_id" => id, "level" => to_string(s.level), "years" => s.years}
      end
    end)
  end

  # The requester's scope, acting on their behalf; the system's when they're gone.
  defp on_behalf(%{requested_by_user_id: nil} = a), do: Scope.system(%{id: a.organisation_id})

  defp on_behalf(a) do
    case Accounts.get_user(a.requested_by_user_id) do
      nil -> Scope.system(%{id: a.organisation_id})
      user -> Grants.scope_for(user, via: :system)
    end
  end
end
