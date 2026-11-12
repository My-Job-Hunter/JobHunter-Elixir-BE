defmodule Core.Leads.Notices do
  @moduledoc """
  Who is told what about a lead (AQ-04A §10.1, QP4a-13), **inside the
  verb's transaction**, each row ensured by its dedupe key
  (`Core.Notifications.ensure/2`, which plans the row's
  deliveries in the same transaction, AQ-08 §7.1) and its words **frozen in the recipient's
  terms**, as P2's are.

  | Kind | Who | Dedupe key |
  |---|---|---|
  | `leads.assigned` | the new owner, when someone else made them owner | `lead:<id>:owner:<event id>` |
  | `leads.moved` | the owner, when someone else (staff or the customer) moved their lead's state, stage or outcome | `lead:<id>:moved:<event id>` |
  | `leads.applied_again` | the **team leads** of the lead's team | `lead:<id>:again:<event id>` |
  | `leads.customer_update` | the customer, for a customer-visible move that isn't a milestone: applied, a stage, an outcome, reopened | `lead:<id>:customer:<event id>` |
  | `leads.customer_milestone` | the customer, when their lead reaches an interview stage, an offer or *Hired* (AQ-08 QP8-4: with push and email) | `lead:<id>:customer:<event id>` |

  Staff read the actor's first name (the customer's acts by the customer's
  name); the customer reads the first name only when the lead's team has
  `customer_sees_staff_names` on, else "The team" — and then the row carries
  no actor at all. Nobody is told of their own act. Each row's deliveries
  are planned by the seam (AQ-08 §7.1).

  Each function answers the socket events its new rows make
  (`notification_created`), for `Core.Tasks.Write.commit/1` to send after
  commit.
  """

  alias Core.Leads.Words
  alias Core.Notifications
  alias Core.Realtime
  alias Core.Tasks.Person
  alias Data.Accounts
  alias Data.Scope
  alias Data.Teams

  @doc "`leads.assigned` to the new owner."
  @spec assigned(Scope.t(), map(), map()) :: list()
  def assigned(scope, lead, event) do
    actor = actor(scope)

    tell(scope, lead.owner_user_id, "leads.assigned", lead,
      title: "#{name(actor, lead)} handed you #{Words.job(lead.job)}",
      body: "#{lead.profile.customer.display_name} · #{lead.profile.title}",
      actor: actor,
      dedupe: "lead:#{lead.id}:owner:#{event.id}"
    )
  end

  @doc "`leads.moved` to the owner: \"Fiza moved “Backend Developer · Bamboo Invest” to Technical interview 1.\""
  @spec moved(Scope.t(), map(), map(), String.t()) :: list()
  def moved(scope, lead, event, to) do
    actor = actor(scope)

    tell(scope, lead.owner_user_id, "leads.moved", lead,
      title: "#{name(actor, lead)} moved #{Words.job(lead.job)} to #{to}.",
      body: "#{lead.profile.customer.display_name} · #{lead.profile.title}",
      actor: actor,
      dedupe: "lead:#{lead.id}:moved:#{event.id}"
    )
  end

  @doc "`leads.applied_again` to the team leads of the lead's team, with the reason."
  @spec applied_again(Scope.t(), map(), map()) :: list()
  def applied_again(scope, lead, event) do
    actor = actor(scope)

    for member <- Teams.list_members(lead.job.team_id), member.role == :lead do
      tell(scope, member.user_id, "leads.applied_again", lead,
        title:
          "#{name(actor, lead)} applied again as #{Words.quoted(lead.profile.title)} " <>
            "on #{Words.job(lead.job)}",
        body: event.note,
        actor: actor,
        dedupe: "lead:#{lead.id}:again:#{event.id}"
      )
    end
  end

  @doc """
  `leads.customer_update` to the customer: `what` is `:applied`, `{:stage,
  stage}` (the stage moved to), `{:outcome, outcome}` or `:reopened`. "The team applied to
  “Backend Developer” at Bamboo Invest as “Golang backend”."

  **A milestone is its own kind** (AQ-08 QP8-4): a move to an interview
  stage (`interview`, `ai_interview`, `final`, or a custom stage anchored to
  one), to an offer, or the outcome *Hired* raises
  `leads.customer_milestone` in the same words, which also pushes and
  emails the customer.
  """
  @spec customer_update(Scope.t(), map(), map(), term()) :: list()
  def customer_update(scope, lead, event, what) do
    customer = lead.profile.customer

    case customer.user_id do
      nil ->
        []

      user_id ->
        names? = Teams.get_settings(lead.job.team_id).customer_sees_staff_names
        actor = actor(scope)
        {who, actor} = for_customer(actor, names?)

        kind =
          if milestone?(lead, what), do: "leads.customer_milestone", else: "leads.customer_update"

        tell(scope, user_id, kind, lead,
          title: customer_words(who, lead, what),
          actor: actor,
          link: "/applications/#{lead.id}",
          dedupe: "lead:#{lead.id}:customer:#{event.id}"
        )
    end
  end

  @milestone_stages [:interview, :ai_interview, :final, :offer]

  @doc """
  Whether a customer-visible move is a milestone (AQ-08 §6): an interview
  stage, an offer, *Hired*.
  """
  @spec milestone?(map(), term()) :: boolean()
  def milestone?(_lead, {:outcome, outcome}), do: outcome == :hired

  def milestone?(_lead, {:stage, %{kind: :custom, anchor_kind: kind}}),
    do: kind in @milestone_stages

  def milestone?(_lead, {:stage, %{kind: kind}}), do: kind in @milestone_stages
  def milestone?(_lead, _what), do: false

  defp customer_words(who, lead, :applied),
    do: "#{who} applied to #{Words.job_at(lead.job)} as #{Words.quoted(lead.profile.title)}."

  defp customer_words(who, lead, {:stage, %{name: stage}}),
    do: "#{who} moved your application to #{Words.job_at(lead.job)} to #{stage}."

  defp customer_words(who, lead, {:outcome, outcome}),
    do: "#{who} marked your application to #{Words.job_at(lead.job)} #{Words.outcome(outcome)}."

  defp customer_words(who, lead, :reopened),
    do: "#{who} reopened your application to #{Words.job_at(lead.job)}."

  # ── Helpers ─────────────────────────────────────────────────────────────────

  # The actor as the customer is told: their first name, or "The team" and
  # no actor on the row.
  defp for_customer(nil, _names?), do: {"The team", nil}
  defp for_customer(actor, true), do: {Person.first_name(actor) || "The team", actor}
  defp for_customer(_actor, false), do: {"The team", nil}

  defp actor(scope) do
    case Scope.user_id(scope) do
      nil -> nil
      id -> Accounts.get_user(id)
    end
  end

  defp name(nil, _lead), do: "The team"

  # The team knows the customer by the customer's name, not the account's.
  defp name(%{id: id}, %{profile: %{customer: %{user_id: id, display_name: customer_name}}}),
    do: customer_name

  defp name(actor, _lead), do: Person.first_name(actor) || "Someone"

  defp tell(scope, user_id, kind, lead, opts) do
    if is_nil(user_id) or user_id == Scope.user_id(scope) do
      []
    else
      actor = opts[:actor]

      {:ok, row} =
        Notifications.ensure(scope, %{
          organisation_id: lead.organisation_id,
          user_id: user_id,
          notification_kind_key: kind,
          actor_user_id: actor && actor.id,
          lead_id: lead.id,
          title: opts[:title],
          body: opts[:body],
          link_path: opts[:link] || "/leads/#{lead.id}",
          dedupe_key: opts[:dedupe]
        })

      if row.is_new,
        do: [Realtime.to_user(row.user_id, "notification_created", %{id: row.id})],
        else: []
    end
  end
end
