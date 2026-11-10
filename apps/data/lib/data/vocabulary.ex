defmodule Data.Vocabulary do
  @moduledoc """
  The domain strings shared with the frontend, in their order.

  **Change both or neither** (PLAN §20). The frontend's `packages/core` holds
  the same lists; `apps/data/priv/vocabulary.json` is what it is checked
  against. `mix jh.vocabulary` rewrites that file from this module, and
  `Data.VocabularyTest` fails when the two disagree, so a value added here and
  not exported is a red build rather than a screen that cannot render it.

  **The order is meaningful.** States run in the order a lead or a task moves
  through them, and pickers list values as written here.

  A schema that stores one of these uses `Ecto.Enum` over the list *and* a
  `CHECK` constraint named `<field>_known` (`Core.ConventionsTest`).

  ## Custom stages

  `stage_kinds` are the **engine kinds**. A pipeline may add its own stages,
  stored as `"custom.<slug>"` and anchored to an engine kind (PLAN §6.2,
  AutoCare's stage templates). They are not listed here because they are
  data, not vocabulary: `custom_stage?/1` recognises one.
  """

  @roles ~w(admin manager lead member customer)
  @team_member_roles ~w(manager lead member)
  @lead_states ~w(to_do in_progress on_hold done archived)
  @lead_outcomes ~w(hired rejected withdrawn position_closed no_response not_pursued)
  @stage_kinds ~w(inbound applied seen screening assessment interview ai_interview final offer negotiation contract)
  @task_statuses ~w(draft todo in_progress on_hold done closed archived)
  @platforms ~w(linkedin upwork indeed fiverr yc_waas wellfound email other)
  @engagement_types ~w(full_time part_time contract freelance_hourly freelance_fixed internship temporary other)
  @workplace_types ~w(remote hybrid on_site unknown)
  @comp_periods ~w(hour day week month year project)
  @apply_methods ~w(in_platform_easy external_ats proposal email brief_response referral recruiter_inbound other)
  @channel_operators ~w(customer agency staff_login)
  @approval_kinds ~w(reply proposal cv_for_job cover_letter rate asset profile_change other)
  @approval_states ~w(draft pending approved changes_requested rejected withdrawn expired)
  @meeting_kinds ~w(screening technical assessment_review ai_interview final client_call other)
  @meeting_platforms ~w(zoom google_meet teams upwork phone on_site other)
  @customer_statuses ~w(invited active paused ended)
  @seniorities ~w(entry associate mid_senior director executive internship not_applicable)
  @profile_statuses ~w(active paused)
  @pipeline_keys ~w(employment freelance)
  @skill_levels ~w(familiar working strong expert)
  @channel_listeners ~w(none extension forwarding oauth)
  @channel_statuses ~w(active paused disconnected)
  @document_kinds ~w(cv cover_letter_template portfolio certificate other)

  @custom_stage_prefix "custom."

  @doc "Organisation roles."
  def roles, do: @roles
  @doc "The roles a person can hold inside one team."
  def team_member_roles, do: @team_member_roles
  @doc "A lead's columns (PLAN §6.2)."
  def lead_states, do: @lead_states
  @doc "Why a lead is done."
  def lead_outcomes, do: @lead_outcomes
  @doc "The engine stage kinds a pipeline's stages anchor to."
  def stage_kinds, do: @stage_kinds
  @doc "A task's statuses, as AutoCare's board has them."
  def task_statuses, do: @task_statuses
  @doc "Where a job or a channel lives."
  def platforms, do: @platforms
  @doc "How a job pays and binds."
  def engagement_types, do: @engagement_types
  @doc "Where the work happens."
  def workplace_types, do: @workplace_types
  @doc "The period a compensation figure is per."
  def comp_periods, do: @comp_periods
  @doc "How an application was made."
  def apply_methods, do: @apply_methods
  @doc "Who operates a customer's platform account (Q3)."
  def channel_operators, do: @channel_operators
  @doc "What an approval asks about."
  def approval_kinds, do: @approval_kinds
  @doc "An approval's life (PLAN §9.3)."
  def approval_states, do: @approval_states
  @doc "What a meeting is for."
  def meeting_kinds, do: @meeting_kinds
  @doc "Where a meeting happens."
  def meeting_platforms, do: @meeting_platforms
  @doc "A customer's life (JH-01 §4.3): invited until the portal invite is accepted."
  def customer_statuses, do: @customer_statuses
  @doc "A profile's seniority, LinkedIn's ladder."
  def seniorities, do: @seniorities
  @doc "Whether a profile is being worked."
  def profile_statuses, do: @profile_statuses
  @doc "The two default pipelines a profile may lead into (the table arrives in P4a)."
  def pipeline_keys, do: @pipeline_keys
  @doc "How well a profile holds a skill."
  def skill_levels, do: @skill_levels
  @doc "How a channel is listened to (P5, P9); `none` in P1."
  def channel_listeners, do: @channel_listeners
  @doc "A channel's state."
  def channel_statuses, do: @channel_statuses
  @doc "What a document is."
  def document_kinds, do: @document_kinds

  @doc """
  Every list, by name — what `priv/vocabulary.json` holds.
  """
  @spec all() :: %{atom() => [String.t()]}
  def all do
    %{
      roles: @roles,
      team_member_roles: @team_member_roles,
      lead_states: @lead_states,
      lead_outcomes: @lead_outcomes,
      stage_kinds: @stage_kinds,
      task_statuses: @task_statuses,
      platforms: @platforms,
      engagement_types: @engagement_types,
      workplace_types: @workplace_types,
      comp_periods: @comp_periods,
      apply_methods: @apply_methods,
      channel_operators: @channel_operators,
      approval_kinds: @approval_kinds,
      approval_states: @approval_states,
      meeting_kinds: @meeting_kinds,
      meeting_platforms: @meeting_platforms,
      customer_statuses: @customer_statuses,
      seniorities: @seniorities,
      profile_statuses: @profile_statuses,
      pipeline_keys: @pipeline_keys,
      skill_levels: @skill_levels,
      channel_listeners: @channel_listeners,
      channel_statuses: @channel_statuses,
      document_kinds: @document_kinds
    }
  end

  @doc """
  Whether a stage key is a pipeline's own (`"custom.<slug>"`) rather than an
  engine kind.

      iex> Data.Vocabulary.custom_stage?("custom.take_home")
      true
      iex> Data.Vocabulary.custom_stage?("interview")
      false
  """
  @spec custom_stage?(String.t()) :: boolean()
  def custom_stage?(@custom_stage_prefix <> slug), do: slug != ""
  def custom_stage?(_key), do: false

  @doc """
  `all/0` as the JSON the frontend reads: pretty, keys sorted, values in
  order, with a trailing newline.
  """
  @spec to_json() :: String.t()
  def to_json do
    all()
    |> Enum.map(fn {name, values} -> {Atom.to_string(name), values} end)
    |> Enum.sort_by(fn {name, _values} -> name end)
    |> Jason.OrderedObject.new()
    |> Jason.encode!(pretty: true)
    |> Kernel.<>("\n")
  end

  @doc """
  Where the exported file lives in the source tree: `apps/data/priv`.

  The source path, not `Application.app_dir/2`: the file is committed and
  read by the frontend, so the build directory is the wrong place to write it.
  """
  @spec json_path() :: Path.t()
  def json_path, do: Path.expand("../../priv/vocabulary.json", __DIR__)
end
