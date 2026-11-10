defmodule Core.Audit.Labels do
  @moduledoc """
  A human label for an audit row's subject — a person's name, a team's
  name, a profile's title — so the log reads "Dawud renamed **Backend
  squad**" rather than a uuid. Resolved in one query per subject kind for a
  page of events; a subject that has gone (or a kind with no label) is nil.

  The table here is the only place `subject_kind` strings are interpreted,
  and the audit log is the one place a `kind + id` pair is allowed (AutoCare
  §8a D3).
  """

  import Ecto.Query, warn: false

  alias Data.Accounts.User
  alias Data.Audit.AuditEvent
  alias Data.Repo

  # `{kind, schema, field}`: the row's own label column.
  @direct [
    {"organisations", Data.Organisations.Organisation, :name},
    {"teams", Data.Teams.Team, :name},
    {"persons", Data.Accounts.Person, :display_name},
    {"invitations", Data.Invitations.Invitation, :email},
    {"customers", Data.Customers.Customer, :display_name},
    {"profiles", Data.Customers.Profile, :title},
    {"channels", Data.Customers.Channel, :handle},
    {"documents", Data.Customers.Document, :label},
    {"skills", Data.Customers.Skill, :name}
  ]

  # `{kind, schema, key}`: rows whose label is a user's name, where `key` is
  # the audit's `subject_id` and `user_id` points at the user.
  @through_user [
    {"team_members", Data.Teams.TeamMember, :id},
    {"org_admins", Data.Organisations.OrgAdmin, :id},
    {"user_settings", Data.Accounts.UserSettings, :user_id}
  ]

  @doc "The events with `subject_label` filled where a label exists."
  @spec attach([AuditEvent.t()]) :: [AuditEvent.t()]
  def attach(events) do
    labels = for_events(events)
    Enum.map(events, &%{&1 | subject_label: labels[{&1.subject_kind, &1.subject_id}]})
  end

  @doc "`%{{subject_kind, subject_id} => label}` for every event that has one."
  @spec for_events([AuditEvent.t()]) :: %{{String.t(), binary()} => String.t()}
  def for_events(events) do
    by_kind = Enum.group_by(events, & &1.subject_kind, & &1.subject_id)

    %{}
    |> direct(by_kind)
    |> through_user(by_kind)
    |> Map.merge(users(by_kind["users"] || []))
  end

  defp direct(acc, by_kind) do
    for {kind, schema, field} <- @direct, ids = by_kind[kind], ids != [], reduce: acc do
      acc ->
        from(r in schema, where: r.id in ^ids, select: {r.id, field(r, ^field)})
        |> Repo.all()
        |> Enum.reduce(acc, fn {id, label}, acc -> Map.put(acc, {kind, id}, label) end)
    end
  end

  defp through_user(acc, by_kind) do
    for {kind, schema, key} <- @through_user, ids = by_kind[kind], ids != [], reduce: acc do
      acc ->
        from(r in schema,
          join: u in User,
          on: u.id == r.user_id,
          join: p in assoc(u, :person),
          where: field(r, ^key) in ^ids,
          select: {field(r, ^key), p.display_name}
        )
        |> Repo.all()
        |> Enum.reduce(acc, fn {id, label}, acc -> Map.put(acc, {kind, id}, label) end)
    end
  end

  defp users([]), do: %{}

  defp users(ids) do
    from(u in User,
      join: p in assoc(u, :person),
      where: u.id in ^ids,
      select: {u.id, p.display_name}
    )
    |> Repo.all()
    |> Map.new(fn {id, name} -> {{"users", id}, name} end)
  end
end
