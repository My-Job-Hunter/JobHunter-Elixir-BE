defmodule Core.Approvals.Ask do
  @moduledoc """
  What a request for approval carries, read and checked (AQ-07 §11.4):
  the kind, **what it is about** (and whether the caller may ask about
  it), the **proposed** value as the kind's typed columns, the files, the
  due date, and **who decides** — the customer's policy, or the slots the
  requester picks for an ad hoc kind. `Core.Approvals` (draft, edit) and
  `Core.Approvals.Act` (revise) call these before their transaction, so a
  body the verb cannot act on is a field error and nothing is written.

  **What it is about** (§5.1): a lead for every kind but `profile_change`
  (a profile) and `reply` (a lead, or a conversation — or the message it
  answers, whose conversation it is; a conversation on one lead names that
  lead). The team is the lead's, the conversation's, or — for a profile
  change — `team_id`, a team serving the customer that the caller is in
  (QP7-1). Who may ask is `Core.Access.Approvals` (QP7-2).
  """

  alias Core.Access
  alias Core.Approvals.{Policies, Proposed}
  alias Core.Conversations
  alias Core.Leads
  alias Core.Media
  alias Data.Conversations, as: ConversationStore
  alias Data.Scope
  alias Data.Teams
  alias Data.Vocabulary

  @kinds Vocabulary.approval_kinds()
  @kind_atoms Enum.map(@kinds, &String.to_atom/1)
  @max_files 20

  # ── The kind ────────────────────────────────────────────────────────────────

  @doc "`approval_kind` as sent, one of the vocabulary's."
  @spec kind(term()) :: {:ok, atom()} | {:error, term()}
  def kind(nil), do: {:error, {:missing, [:approval_kind]}}

  def kind(value) do
    case pick(value, @kind_atoms) do
      nil -> Leads.invalid("approval_kind", "is one of #{Enum.join(@kinds, ", ")}")
      kind -> {:ok, kind}
    end
  end

  @doc """
  A value of a closed list as its atom, or `nil` — never minting one: the
  list's atoms are the caller's own, made when it compiled, so they exist
  however early the request comes.
  """
  @spec pick(term(), [atom()]) :: atom() | nil
  def pick(nil, _atoms), do: nil
  def pick(value, atoms), do: Enum.find(atoms, &(Atom.to_string(&1) == to_string(value)))

  @doc "`title`: required, at most 200 characters."
  @spec title(term()) :: {:ok, String.t()} | {:error, term()}
  def title(value) when is_binary(value) do
    case String.trim(value) do
      "" ->
        {:error, {:missing, [:title]}}

      t ->
        if String.length(t) > 200,
          do: Leads.invalid("title", "is too long (200 at most)"),
          else: {:ok, t}
    end
  end

  def title(nil), do: {:error, {:missing, [:title]}}
  def title(_value), do: Leads.invalid("title", "is text")

  @doc "`body_md`: markdown, at most 20,000 characters; none is empty."
  @spec body(term()) :: {:ok, String.t()} | {:error, term()}
  def body(nil), do: {:ok, ""}

  def body(value) when is_binary(value) do
    if String.length(value) > 20_000,
      do: Leads.invalid("body_md", "is too long (20,000 at most)"),
      else: {:ok, String.trim(value)}
  end

  def body(_value), do: Leads.invalid("body_md", "is text")

  # ── What it is about ────────────────────────────────────────────────────────

  @doc """
  What the approval is about: `%{team, customer, lead, profile,
  conversation, message}` (the ones its kind has), once the caller may ask
  about it and `team_id` is its team.
  """
  @spec about(Scope.t(), atom(), map()) :: {:ok, map()} | {:error, term()}
  def about(%Scope{} = scope, :profile_change, params) do
    with {:ok, profile} <- profile(scope, params["profile_id"]),
         {:ok, team} <- profile_team(scope, profile, params["team_id"]) do
      {:ok, %{team: team, customer: profile.customer, profile: profile, lead: nil}}
    end
  end

  def about(%Scope{} = scope, :reply, params) do
    with {:ok, message} <- message(scope, params["message_id"]),
         {:ok, conversation} <- conversation(scope, params["conversation_id"], message),
         {:ok, lead} <- reply_lead(scope, params["lead_id"], conversation),
         :ok <- linked(conversation, lead),
         :ok <- may_reply(scope, lead, conversation),
         {:ok, team, customer} <- reply_where(lead, conversation),
         :ok <- same_team(team, params["team_id"]) do
      {:ok,
       %{
         team: team,
         customer: customer,
         lead: lead,
         conversation: conversation,
         message: message,
         profile: nil
       }}
    end
  end

  def about(%Scope{} = scope, kind, params) do
    with {:ok, lead} <- lead(scope, kind, params["lead_id"]),
         :ok <- same_team(lead.job.team, params["team_id"]) do
      {:ok, %{team: lead.job.team, customer: lead.profile.customer, lead: lead, profile: nil}}
    end
  end

  defp lead(_scope, _kind, id) when id in [nil, ""], do: {:error, {:missing, [:lead_id]}}

  defp lead(scope, kind, id) do
    with %{} = lead <- Data.Leads.get(Scope.organisation_id(scope), id) || {:error, :not_found},
         :ok <-
           Access.why_not(
             scope,
             :create,
             {:approval_request, %{approval_kind: kind, lead: Leads.subject(lead)}}
           ),
         do: {:ok, lead}
  end

  defp profile(_scope, id) when id in [nil, ""], do: {:error, {:missing, [:profile_id]}}

  defp profile(scope, id) do
    with %{} = profile <- Data.Profiles.get(id) || {:error, :not_found},
         true <-
           profile.customer.organisation_id == Scope.organisation_id(scope) ||
             {:error, :not_found},
         :ok <-
           Access.why_not(
             scope,
             :create,
             {:approval_request, %{approval_kind: :profile_change, profile: profile}}
           ) do
      if profile.archived_at, do: Leads.invalid("profile_id", "is archived"), else: {:ok, profile}
    end
  end

  # QP7-1: the requester's team serving the customer, named by `team_id`.
  defp profile_team(_scope, _profile, id) when id in [nil, ""],
    do: {:error, {:missing, [:team_id]}}

  defp profile_team(scope, profile, id) do
    customer = profile.customer

    case Teams.get(Scope.organisation_id(scope), to_string(id)) do
      %{archived_at: nil} = team ->
        cond do
          team.id not in customer.team_ids ->
            Leads.invalid("team_id", "doesn't serve #{customer.display_name}")

          not (Scope.admin?(scope) or not is_nil(Scope.team_role(scope, team.id))) ->
            Leads.invalid("team_id", "isn't one of your teams")

          true ->
            {:ok, team}
        end

      _other ->
        Leads.invalid("team_id", "isn't a team")
    end
  end

  defp same_team(_team, id) when id in [nil, ""], do: {:error, {:missing, [:team_id]}}

  defp same_team(team, id),
    do: if(to_string(id) == team.id, do: :ok, else: Leads.invalid("team_id", "isn't its team"))

  defp message(_scope, id) when id in [nil, ""], do: {:ok, nil}

  defp message(scope, id) do
    case ConversationStore.message(Scope.organisation_id(scope), id) do
      nil -> Leads.invalid("message_id", "is not a message")
      m -> {:ok, m}
    end
  end

  defp conversation(_scope, id, nil) when id in [nil, ""], do: {:ok, nil}

  defp conversation(scope, id, message) do
    org = Scope.organisation_id(scope)
    id = if id in [nil, ""], do: message.conversation_id, else: to_string(id)

    case ConversationStore.get(org, id) do
      nil ->
        Leads.invalid("conversation_id", "is not a conversation")

      c ->
        if message && message.conversation_id != c.id,
          do: Leads.invalid("message_id", "is not a message of this conversation"),
          else: {:ok, c}
    end
  end

  # A conversation on one lead names that lead.
  defp reply_lead(scope, id, conversation) when id in [nil, ""] do
    case conversation && conversation.links do
      nil -> {:error, {:missing, [:lead_id]}}
      [%{lead: lead}] -> {:ok, Data.Leads.reload(lead) |> then(&visible(scope, &1))}
      _none_or_many -> {:ok, nil}
    end
  end

  defp reply_lead(scope, id, _conversation) do
    case Data.Leads.get(Scope.organisation_id(scope), id) do
      nil -> {:error, :not_found}
      lead -> {:ok, lead}
    end
  end

  defp visible(scope, lead),
    do: if(Access.can?(scope, :read, {:lead, Leads.subject(lead)}), do: lead, else: nil)

  defp linked(nil, _lead), do: :ok
  defp linked(_conversation, nil), do: :ok

  defp linked(conversation, lead) do
    if Enum.any?(conversation.links, &(&1.lead_id == lead.id)),
      do: :ok,
      else: Leads.invalid("conversation_id", "isn't on this lead")
  end

  defp may_reply(scope, %{} = lead, _conversation) do
    Access.why_not(
      scope,
      :create,
      {:approval_request, %{approval_kind: :reply, lead: Leads.subject(lead)}}
    )
  end

  defp may_reply(scope, nil, conversation),
    do: Access.why_not(scope, :write, {:conversation, Conversations.subject(conversation)})

  defp reply_where(%{} = lead, _conversation), do: {:ok, lead.job.team, lead.profile.customer}

  defp reply_where(nil, conversation) do
    case conversation.customer_id do
      nil ->
        Leads.invalid("conversation_id", "isn't about a customer yet")

      customer_id ->
        customer = Data.Customers.get(conversation.organisation_id, customer_id)
        {:ok, Teams.get(conversation.organisation_id, conversation.team_id), customer}
    end
  end

  # ── The proposed value (`Core.Approvals.Proposed`) ──────────────────────────

  @doc "`proposed` as the kind's typed columns (`Core.Approvals.Proposed.columns/3`)."
  defdelegate proposed(kind, raw, about), to: Proposed, as: :columns

  # ── Files, due ──────────────────────────────────────────────────────────────

  @doc """
  `media_ids`: each a confirmed attachment the caller uploaded, or a file
  already on one of this approval's versions (`held`). In order, once each.
  """
  @spec media(Scope.t(), term(), [binary()]) :: {:ok, [binary()]} | {:error, term()}
  def media(_scope, nil, _held), do: {:ok, []}

  def media(%Scope{} = scope, ids, held) when is_list(ids) do
    ids = ids |> Enum.map(&to_string/1) |> Enum.uniq()

    cond do
      length(ids) > @max_files ->
        Leads.invalid("media_ids", "has more than #{@max_files} files")

      Enum.all?(
        ids,
        &(&1 in held or match?({:ok, _m}, Media.own_uploaded(scope, &1, :attachment)))
      ) ->
        {:ok, ids}

      true ->
        Leads.invalid("media_ids", "names a file that isn't an upload of yours")
    end
  end

  def media(_scope, _ids, _held), do: Leads.invalid("media_ids", "is a list")

  @doc "`due_at`: a time after `now`, or none."
  @spec due(term(), DateTime.t()) :: {:ok, DateTime.t() | nil} | {:error, term()}
  def due(value, _now) when value in [nil, ""], do: {:ok, nil}

  def due(value, now) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, at, _offset} ->
        if DateTime.after?(at, now),
          do: {:ok, at},
          else: Leads.invalid("due_at", "must be in the future")

      _bad ->
        Leads.invalid("due_at", "is not a time")
    end
  end

  def due(_value, _now), do: Leads.invalid("due_at", "is not a time")

  # ── Who decides ─────────────────────────────────────────────────────────────

  @doc """
  The slots and the rule (§8): **the customer's policy** for the kind, to
  which the requester may add named people; for an **ad hoc** kind the
  slots the requester picks (`slots` required) and the rule they choose.
  A slot is `{slot, user_id?}`; a named person is someone in the team (or
  the system admin), never the requester.
  """
  @spec slots(Scope.t(), map(), atom(), map()) :: {:ok, [map()], atom()} | {:error, term()}
  def slots(%Scope{} = scope, about, kind, params) do
    policy = Policies.for_kind(about.customer.id, kind)

    with {:ok, given} <- given_slots(scope, about, params["slots"]),
         {:ok, rule} <- rule(params["rule"], policy),
         {:ok, slots} <- with_policy(policy, given, about.customer),
         do: {:ok, slots, rule}
  end

  defp with_policy(%{needs: :ad_hoc}, [], _customer),
    do: Leads.invalid("slots", "says who decides")

  defp with_policy(%{needs: :ad_hoc}, given, _customer), do: {:ok, given}

  # A named person joins a policy kind only where they can't decide alone:
  # under *any*, their yes would approve without the customer's rule being
  # met (AQ-07's run), so it is refused; under *all* they add a required yes.
  defp with_policy(policy, given, customer) do
    from_policy = Policies.slots(policy)

    cond do
      Enum.any?(given, &(&1.slot != :user and &1 not in from_policy)) ->
        Leads.invalid("slots", "follow #{customer.display_name}'s rules; add a person only")

      policy.rule == :any and Enum.any?(given, &(&1.slot == :user)) ->
        Leads.invalid(
          "slots",
          "can't add a person here: #{customer.display_name}'s rules say who decides"
        )

      true ->
        {:ok, Enum.uniq(from_policy ++ given)}
    end
  end

  defp rule(nil, policy), do: {:ok, policy.rule}
  defp rule("", policy), do: {:ok, policy.rule}

  defp rule(value, policy) do
    rule = pick(value, [:any, :all])

    cond do
      is_nil(rule) ->
        Leads.invalid("rule", "is any or all")

      policy.needs != :ad_hoc and rule != policy.rule ->
        Leads.invalid("rule", "follows the customer's rules")

      true ->
        {:ok, rule}
    end
  end

  defp given_slots(_scope, _about, nil), do: {:ok, []}

  defp given_slots(scope, about, list) when is_list(list) do
    list
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {raw, i}, {:ok, acc} ->
      case slot(scope, about, Leads.stringify(raw)) do
        {:ok, slot} -> {:cont, {:ok, [slot | acc]}}
        {:error, field, message} -> {:halt, Leads.invalid("slots.#{i}.#{field}", message)}
      end
    end)
    |> then(fn
      {:ok, acc} -> {:ok, acc |> Enum.reverse() |> Enum.uniq()}
      error -> error
    end)
  end

  defp given_slots(_scope, _about, _other), do: Leads.invalid("slots", "is a list")

  defp slot(scope, about, %{"slot" => "user", "user_id" => id}) when is_binary(id) do
    with {:ok, uuid} <- Ecto.UUID.cast(id),
         true <- uuid != Scope.user_id(scope) || {:error, "is you: someone else decides"},
         true <- reviewer?(about, uuid) || {:error, "isn't in this team"} do
      {:ok, %{slot: :user, user_id: uuid}}
    else
      {:error, message} -> {:error, "user_id", message}
      :error -> {:error, "user_id", "isn't in this team"}
    end
  end

  defp slot(_scope, _about, %{"slot" => "user"}), do: {:error, "user_id", "is required"}
  defp slot(_scope, _about, %{"slot" => "customer"}), do: {:ok, %{slot: :customer, user_id: nil}}

  defp slot(_scope, _about, %{"slot" => "team_lead"}),
    do: {:ok, %{slot: :team_lead, user_id: nil}}

  defp slot(_scope, _about, _other), do: {:error, "slot", "is customer, team_lead or user"}

  # Someone in the approval's team, or the system admin (in no team).
  defp reviewer?(about, user_id) do
    not is_nil(Teams.get_open_member(about.team.id, user_id)) or
      about.team.organisation_id in Data.Organisations.admin_of(user_id)
  end
end
