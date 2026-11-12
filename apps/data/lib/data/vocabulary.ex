defmodule Data.Vocabulary do
  @moduledoc """
  The domain strings shared with the frontend, in their order.

  **Change both or neither** (PLAN §20). The frontend's `packages/core` holds
  the same lists; `apps/data/priv/vocabulary.json` is what it is checked
  against. `mix aq.vocabulary` rewrites that file from this module, and
  `Data.VocabularyTest` fails when the two disagree, so a value added here and
  not exported is a red build rather than a screen that cannot render it.

  **The order is meaningful.** States run in the order a lead or a task moves
  through them, and pickers list values as written here. Every list is
  strings except `task_reminders`, which is minutes.

  A schema that stores one of these uses `Ecto.Enum` over the list *and* a
  `CHECK` constraint named `<field>_known` (`Core.ConventionsTest`).

  ## Custom stages

  `stage_kinds` are the **engine kinds**. A pipeline may add its own stages,
  stored as `"custom.<slug>"` and anchored to an engine kind (PLAN §6.2,
  mCart's stage templates). They are not listed here because they are
  data, not vocabulary: `custom_stage?/1` recognises one.
  """

  @roles ~w(admin lead member customer)
  @team_member_roles ~w(lead member)
  @lead_states ~w(todo in_progress on_hold done)
  @lead_outcomes ~w(hired rejected withdrawn position_closed no_response not_pursued)
  @stage_kinds ~w(inbound applied seen screening assessment interview ai_interview final offer negotiation contract)
  @task_states ~w(draft todo in_progress on_hold done closed)
  @task_priorities ~w(low high urgent)
  @task_close_reasons ~w(not_needed wont_do duplicate withdrawn)
  @task_customer_access ~w(none shared assigned)
  @task_relation_kinds ~w(relates_to blocks duplicates)
  @task_sources ~w(staff customer)
  @task_history_fields ~w(created title description state stage priority due reminder team customer
                          profile customer_access private assignees watchers checklist step link
                          relation file archived)
  @task_reminders [0, 60, 1440]
  @platforms ~w(linkedin upwork indeed fiverr yc_waas wellfound email other)
  @engagement_types ~w(full_time part_time contract freelance_hourly freelance_fixed internship temporary other)
  @workplace_types ~w(remote hybrid on_site unknown)
  @comp_periods ~w(hour day week month year project)
  @apply_methods ~w(in_platform_easy external_ats proposal email brief_response referral recruiter_inbound other)
  @channel_operators ~w(customer agency staff_login)
  @approval_kinds ~w(reply proposal cv_for_job cover_letter rate asset profile_change other)
  @approval_states ~w(draft pending approved changes_requested rejected withdrawn expired)
  @approval_rules ~w(any all)
  @approval_needs ~w(customer team_lead both ad_hoc)
  @reviewer_slots ~w(customer team_lead user)
  @approval_decisions ~w(approved changes_requested rejected)
  @approval_effects ~w(none ready sent applied failed)
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
  @job_sources ~w(linkedin upwork indeed yc_waas wellfound fiverr greenhouse lever ashby workable
                  company_site email other)
  @job_origins ~w(manual extension email import)
  @job_statuses ~w(open closed unknown)
  @job_close_reasons ~w(filled expired withdrawn other)
  @remote_scopes ~w(global region country_list unknown)
  @regions ~w(europe eu uk_ireland north_america us canada latam emea apac mena south_asia africa
              oceania)
  @visa_policies ~w(yes no existing_auth_only unknown)
  @durations ~w(lt_1m 1_3m 3_6m gt_6m)
  @comp_sources ~w(employer platform_estimate parsed_text)
  @equity_kinds ~w(options rsu profit_share unknown)
  @company_size_bands ~w(1_10 11_50 51_200 201_500 501_1000 1001_5000 5001_plus)
  @upwork_experience_levels ~w(entry intermediate expert)
  @upwork_spent_bands ~w(none lt_1k 1k_10k 10k_100k 100k_1m gt_1m)
  @job_dismiss_reasons ~w(skills money location seniority company already_known other)
  @suggestion_parts ~w(skills engagement workplace money timezone seniority)
  @peer_access ~w(hidden view edit)
  @share_levels ~w(summary details details_history)
  @lead_event_kinds ~w(saved applied stage_moved state_moved outcome_set reopened owner_changed
                        pipeline_changed cv_set archived unarchived note_added task_created
                        task_done follow_up_due follow_up_logged archive_warned labelled
                        message_in message_out conversation_linked contact_linked
                        contact_unlinked meeting_scheduled meeting_changed meeting_done
                        meeting_cancelled classified approval_requested approval_decided
                        approval_withdrawn)
  @lead_confirmations ~w(by_hand page_confirmation confirmation_email)
  @lead_priorities ~w(low high urgent)
  @bid_periods ~w(hour project)
  @lead_archive_reasons ~w(by_hand inactive)
  @event_actors ~w(user customer extension email system)
  @event_visibilities ~w(staff customer)
  @saved_view_screens ~w(tracker leads jobs board)
  @tracker_columns ~w(applied title company source customer profile owner state outcome next
                      last_activity money workplace engagement cv labels missing)
  @tracker_groups ~w(none state stage customer profile owner source)
  @board_lanes ~w(none customer profile owner source)
  @ext_sites ~w(linkedin upwork)
  @ext_page_kinds ~w(job search proposal confirmation thread other)
  @contact_sources ~w(manual email extension import)
  @contact_handle_kinds ~w(email linkedin upwork phone other)
  @contact_roles ~w(recruiter hiring_manager interviewer client referrer other)
  @match_methods ~w(by_hand headers thread_id sender_handle created_from_triage)
  @match_confidences ~w(sure likely)
  @message_directions ~w(in out)
  @message_from_kinds ~w(contact user customer text)
  @message_captures ~w(manual eml_upload extension forward oauth_sync)
  @message_classes ~w(interested interview_invitation more_info rejection position_closed
                      unsubscribe bounce general)
  @meeting_statuses ~w(scheduled done cancelled no_show)
  @meeting_sources ~w(manual email_invite extension)
  @delivery_channels ~w(push email extension)
  @delivery_states ~w(pending sent skipped failed)
  @delivery_skip_reasons ~w(read no_target preference_off)
  @push_apps ~w(team client)
  @notification_channels ~w(inapp push email extension digest)

  @custom_stage_prefix "custom."

  @doc "The roles (AQ-04A §4.0): the one system admin, a team lead, staff, a customer."
  def roles, do: @roles
  @doc "The roles a person can hold inside one team."
  def team_member_roles, do: @team_member_roles
  @doc "A lead's states (AQ-04A §5.5): archived is a flag (`archived_at`), not a state (QP4a-1)."
  def lead_states, do: @lead_states
  @doc "Why a lead is done."
  def lead_outcomes, do: @lead_outcomes
  @doc "The engine stage kinds a pipeline's stages anchor to."
  def stage_kinds, do: @stage_kinds

  @doc "A task's states, as mCart's board has them (AQ-02 §7.6); archived is a flag, not a state."
  def task_states, do: @task_states
  @doc "A task's priority; none is *normal*."
  def task_priorities, do: @task_priorities
  @doc "Why a task was closed; `withdrawn` is the customer's own."
  def task_close_reasons, do: @task_close_reasons
  @doc "The customer's part in a task (QP2-2): staff only, sees it, has to do it."
  def task_customer_access, do: @task_customer_access
  @doc "How two tasks relate."
  def task_relation_kinds, do: @task_relation_kinds
  @doc "Who made a task."
  def task_sources, do: @task_sources
  @doc "The fields a task's activity names (AQ-02 §5.1)."
  def task_history_fields, do: @task_history_fields
  @doc "Reminder choices in minutes before the due time (QP2-13): at the time, an hour, a day."
  def task_reminders, do: @task_reminders
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

  @doc "Over an approval's slots (AQ-07 QP7-5): *any* approves on the first yes, *all* needs every slot."
  def approval_rules, do: @approval_rules

  @doc "Who a customer's policy asks for a kind (AQ-07 §8): `both` is customer and team lead; `ad_hoc` the requester picks."
  def approval_needs, do: @approval_needs

  @doc "An approval's reviewer slots (AQ-07 QP7-4): the customer, any lead of the team, a named person."
  def reviewer_slots, do: @reviewer_slots
  @doc "What a slot says of a version (AQ-07 §6)."
  def approval_decisions, do: @approval_decisions

  @doc "What approval did (AQ-07 §7, §11.4): nothing, ready to send, sent, applied, or couldn't apply."
  def approval_effects, do: @approval_effects
  @doc "What a meeting is for."
  def meeting_kinds, do: @meeting_kinds
  @doc "Where a meeting happens."
  def meeting_platforms, do: @meeting_platforms
  @doc "A customer's life (AQ-01 §4.3): invited until the portal invite is accepted."
  def customer_statuses, do: @customer_statuses
  @doc "A profile's seniority, LinkedIn's ladder."
  def seniorities, do: @seniorities
  @doc "Whether a profile is being worked."
  def profile_statuses, do: @profile_statuses
  @doc "The two pipelines, by key (AQ-04A §9, QP4a-2)."
  def pipeline_keys, do: @pipeline_keys
  @doc "How well a profile holds a skill."
  def skill_levels, do: @skill_levels
  @doc "How a channel is listened to (P5, P9); `none` in P1."
  def channel_listeners, do: @channel_listeners
  @doc "A channel's state."
  def channel_statuses, do: @channel_statuses
  @doc "What a document is."
  def document_kinds, do: @document_kinds

  @doc "Where a job's link points (AQ-03 QP3-3); the channels keep `platforms`."
  def job_sources, do: @job_sources
  @doc "How a job came into the pool."
  def job_origins, do: @job_origins
  @doc "Whether a job is still taking applications."
  def job_statuses, do: @job_statuses
  @doc "Why a job was marked closed."
  def job_close_reasons, do: @job_close_reasons
  @doc "Where a remote job may be done from."
  def remote_scopes, do: @remote_scopes
  @doc "The regions a remote job may name (`jobs.allowed_regions`)."
  def regions, do: @regions
  @doc "Whether a job sponsors a visa."
  def visa_policies, do: @visa_policies
  @doc "How long an engagement runs."
  def durations, do: @durations
  @doc "Where a job's money figure came from; an estimate is `platform_estimate` (QP3-9)."
  def comp_sources, do: @comp_sources
  @doc "What kind of equity a job offers."
  def equity_kinds, do: @equity_kinds
  @doc "A company's head count, banded."
  def company_size_bands, do: @company_size_bands
  @doc "Upwork's experience levels."
  def upwork_experience_levels, do: @upwork_experience_levels
  @doc "What an Upwork client has spent, banded."
  def upwork_spent_bands, do: @upwork_spent_bands
  @doc "Why a suggested job is not for a profile."
  def job_dismiss_reasons, do: @job_dismiss_reasons
  @doc "The parts of a suggestion's score (AQ-03 §9), in the weight order."
  def suggestion_parts, do: @suggestion_parts

  @doc "What a member sees and does with a teammate's item, per kind (AQ-03B §3.2): `team_settings.peer_*`."
  def peer_access, do: @peer_access
  @doc "How much of an item a share link shows (AQ-03B §3.3)."
  def share_levels, do: @share_levels

  @doc "What a lead's ledger row records (AQ-04A §5.5; later phases add theirs)."
  def lead_event_kinds, do: @lead_event_kinds
  @doc "How an application was confirmed: by hand in P4a; P5 captures the others."
  def lead_confirmations, do: @lead_confirmations
  @doc "A lead's priority; none is *normal*."
  def lead_priorities, do: @lead_priorities
  @doc "What a freelance bid is per."
  def bid_periods, do: @bid_periods
  @doc "Why a lead was archived: by hand, or P4b's inactivity sweep."
  def lead_archive_reasons, do: @lead_archive_reasons
  @doc "Who made a ledger row."
  def event_actors, do: @event_actors
  @doc "Who reads a ledger row: staff only, or the customer too."
  def event_visibilities, do: @event_visibilities
  @doc "The screens a saved view belongs to (AQ-04B §5.1, QP4b-16)."
  def saved_view_screens, do: @saved_view_screens
  @doc "The Tracker's columns, in their default order (AQ-04B §5.4); `sort` is one of them."
  def tracker_columns, do: @tracker_columns
  @doc "What the Tracker groups by (AQ-04B §5.4)."
  def tracker_groups, do: @tracker_groups
  @doc "The lead boards' swimlanes (AQ-04B §5.4, §9): `source` is the platform."
  def board_lanes, do: @board_lanes
  @doc "The sites the extension reads (AQ-05 §5.5): a selector config and a miss name one."
  def ext_sites, do: @ext_sites

  @doc "The kinds of page an adapter tells apart (AQ-05 §5.5; AQ-06 §9 adds `thread`): where a selector missed."
  def ext_page_kinds, do: @ext_page_kinds

  @doc "How a contact came in (AQ-06 §5.1)."
  def contact_sources, do: @contact_sources
  @doc "A contact's ways in (AQ-06 §5.1): one per kind and normalised value in the organisation."
  def contact_handle_kinds, do: @contact_handle_kinds
  @doc "What a contact is on a lead (AQ-06 §5.1)."
  def contact_roles, do: @contact_roles
  @doc "How a conversation was linked to a lead (AQ-06 §7.2)."
  def match_methods, do: @match_methods

  @doc "How sure a link is (AQ-06 §7.2): `sure` for headers and a thread id, `likely` for a sender's handle."
  def match_confidences, do: @match_confidences
  @doc "Which way a message went."
  def message_directions, do: @message_directions

  @doc "Who wrote a message (AQ-06 §11.6): a contact, a staff user, the customer, or a name as written."
  def message_from_kinds, do: @message_from_kinds

  @doc "How a message arrived (AQ-06 §5.2): by hand, an uploaded `.eml`, the extension; P9's forward and sync."
  def message_captures, do: @message_captures
  @doc "A reply's class (AQ-06 §7.3), each moving the lead through P4a's own verb."
  def message_classes, do: @message_classes
  @doc "A meeting's status (QP6-15): a reschedule is an event, not a status."
  def meeting_statuses, do: @meeting_statuses
  @doc "Where a meeting came from: by hand in P6; an invitation (P9), the extension later."
  def meeting_sources, do: @meeting_sources

  @doc "The channels a delivery row is for (AQ-08 §5): in-app is the row itself, the digest is read by the scan."
  def delivery_channels, do: @delivery_channels

  @doc "A delivery's life (AQ-08 §5): waiting, sent, skipped with a reason, failed after three attempts."
  def delivery_states, do: @delivery_states

  @doc "Why a delivery was skipped (AQ-08 §7.2): read before its email went, nowhere to send it, switched off."
  def delivery_skip_reasons, do: @delivery_skip_reasons
  @doc "The app a browser turned push on in (AQ-08 §5): the console or the portal."
  def push_apps, do: @push_apps

  @doc "What a notification kind's `default_channels` holds (AQ-08 §11.4); the kinds' CHECK uses it."
  def notification_channels, do: @notification_channels

  @doc """
  Every list, by name — what `priv/vocabulary.json` holds.
  """
  @spec all() :: %{atom() => [String.t() | integer()]}
  def all do
    %{
      roles: @roles,
      team_member_roles: @team_member_roles,
      lead_states: @lead_states,
      lead_outcomes: @lead_outcomes,
      stage_kinds: @stage_kinds,
      task_states: @task_states,
      task_priorities: @task_priorities,
      task_close_reasons: @task_close_reasons,
      task_customer_access: @task_customer_access,
      task_relation_kinds: @task_relation_kinds,
      task_sources: @task_sources,
      task_history_fields: @task_history_fields,
      task_reminders: @task_reminders,
      platforms: @platforms,
      engagement_types: @engagement_types,
      workplace_types: @workplace_types,
      comp_periods: @comp_periods,
      apply_methods: @apply_methods,
      channel_operators: @channel_operators,
      approval_kinds: @approval_kinds,
      approval_states: @approval_states,
      approval_rules: @approval_rules,
      approval_needs: @approval_needs,
      reviewer_slots: @reviewer_slots,
      approval_decisions: @approval_decisions,
      approval_effects: @approval_effects,
      meeting_kinds: @meeting_kinds,
      meeting_platforms: @meeting_platforms,
      customer_statuses: @customer_statuses,
      seniorities: @seniorities,
      profile_statuses: @profile_statuses,
      pipeline_keys: @pipeline_keys,
      skill_levels: @skill_levels,
      channel_listeners: @channel_listeners,
      channel_statuses: @channel_statuses,
      document_kinds: @document_kinds,
      job_sources: @job_sources,
      job_origins: @job_origins,
      job_statuses: @job_statuses,
      job_close_reasons: @job_close_reasons,
      remote_scopes: @remote_scopes,
      regions: @regions,
      visa_policies: @visa_policies,
      durations: @durations,
      comp_sources: @comp_sources,
      equity_kinds: @equity_kinds,
      company_size_bands: @company_size_bands,
      upwork_experience_levels: @upwork_experience_levels,
      upwork_spent_bands: @upwork_spent_bands,
      job_dismiss_reasons: @job_dismiss_reasons,
      suggestion_parts: @suggestion_parts,
      peer_access: @peer_access,
      share_levels: @share_levels,
      lead_event_kinds: @lead_event_kinds,
      lead_confirmations: @lead_confirmations,
      lead_priorities: @lead_priorities,
      bid_periods: @bid_periods,
      lead_archive_reasons: @lead_archive_reasons,
      event_actors: @event_actors,
      event_visibilities: @event_visibilities,
      saved_view_screens: @saved_view_screens,
      tracker_columns: @tracker_columns,
      tracker_groups: @tracker_groups,
      board_lanes: @board_lanes,
      ext_sites: @ext_sites,
      ext_page_kinds: @ext_page_kinds,
      contact_sources: @contact_sources,
      contact_handle_kinds: @contact_handle_kinds,
      contact_roles: @contact_roles,
      match_methods: @match_methods,
      match_confidences: @match_confidences,
      message_directions: @message_directions,
      message_from_kinds: @message_from_kinds,
      message_captures: @message_captures,
      message_classes: @message_classes,
      meeting_statuses: @meeting_statuses,
      meeting_sources: @meeting_sources,
      delivery_channels: @delivery_channels,
      delivery_states: @delivery_states,
      delivery_skip_reasons: @delivery_skip_reasons,
      push_apps: @push_apps,
      notification_channels: @notification_channels
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
