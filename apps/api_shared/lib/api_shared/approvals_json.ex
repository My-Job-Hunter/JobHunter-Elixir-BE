defmodule ApiShared.ApprovalsJSON do
  @moduledoc """
  The shapes of AQ-07 §11.4, pinned before the build so the three repos
  build to one contract: the **approval row**, the **approval** (the
  sheet), the **version**, the **slot**, the **comment**, the **policy
  row**, the **count** and the **page**. `Core.Approvals` fills them (the
  customer's view is cut in `Core.Approvals.Sheet`); this module lists
  every field by name, so nothing reaches the wire unasked. Keys are
  snake_case, no map is keyed by data, optional members are `null`.
  """

  @person ~w(user_id name photo_url)a
  @can ~w(edit submit decide revise withdraw comment sent)a
  @money ~w(min_minor max_minor currency period source is_estimate is_undisclosed text)a

  @doc "**approval row**."
  def row(r) do
    %{
      id: r.id,
      approval_kind: r.approval_kind,
      state: r.state,
      title: r.title,
      customer: Map.take(r.customer, [:id, :display_name]),
      lead: r.lead && Map.take(r.lead, [:id, :title]),
      profile: r.profile && Map.take(r.profile, [:id, :title]),
      requested_by: person(r.requested_by),
      due_at: r.due_at,
      overdue: r.overdue,
      version: r.version,
      waiting_on: Enum.map(r.waiting_on, &%{slot: &1.slot, person: person(&1.person)}),
      effect: effect(r.effect),
      updated_at: r.updated_at
    }
  end

  @doc "**approval**: the row and the sheet's parts."
  def approval(a) do
    a
    |> row()
    |> Map.merge(%{
      team: a.team && Map.take(a.team, [:id, :name]),
      rule: a.rule,
      slots: Enum.map(a.slots, &slot/1),
      current: version(a.current),
      versions: Enum.map(a.versions, &%{number: &1.number, at: &1.at, by: person(&1.by)}),
      diff: Enum.map(a.diff, &diff/1),
      submitted_at: a.submitted_at,
      decided_at: a.decided_at,
      comments_count: a.comments_count,
      can: Map.take(a.can, @can)
    })
  end

  @doc "**slot**."
  def slot(s) do
    %{
      id: s.id,
      slot: s.slot,
      person: person(s.person),
      decision:
        s.decision &&
          %{
            decision: s.decision.decision,
            note: s.decision.note,
            by: person(s.decision.by),
            at: s.decision.at
          },
      open: s.open
    }
  end

  @doc "**version**."
  def version(v) do
    p = v.proposed

    %{
      number: v.number,
      body_md: v.body_md,
      body_html: v.body_html,
      proposed: %{
        document: p.document && Map.take(p.document, [:id, :label, :version]),
        bid: money(p.bid),
        connects: p.connects,
        expectation: money(p.expectation),
        title: p.title,
        headline: p.headline,
        summary: p.summary,
        skills: Enum.map(p.skills, &Map.take(&1, [:id, :name]))
      },
      attachments:
        Enum.map(v.attachments, &Map.take(&1, [:media_id, :filename, :content_type, :url])),
      by: person(v.by),
      at: v.at
    }
  end

  @doc "**comment**."
  def comment(c) do
    %{
      id: c.id,
      body_md: c.body_md,
      author: person(c.author),
      at: c.at,
      deleted: c.deleted,
      can: Map.take(c.can, [:delete])
    }
  end

  @doc "**policy row**."
  def policy(p),
    do: Map.take(p, [:approval_kind, :needs, :rule, :auto_approve_hours, :is_default])

  @doc "**count**."
  def count(c), do: %{waiting_on_me: c.waiting_on_me}

  @doc "**page**: `{items: [approval row], next_cursor}`."
  def page(p), do: %{items: Enum.map(p.items, &row/1), next_cursor: p.next_cursor}

  defp diff(d), do: %{field: d.field, parts: Enum.map(d.parts, &Map.take(&1, [:op, :text]))}

  defp effect(e), do: %{state: e.state, words: e.words}

  defp money(nil), do: nil
  defp money(m), do: Map.take(m, @money)

  defp person(nil), do: nil
  defp person(p), do: Map.take(p, @person)
end
