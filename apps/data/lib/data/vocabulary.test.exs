defmodule Data.VocabularyTest do
  @moduledoc """
  The shared strings, asserted against the file the frontend reads.
  """

  use ExUnit.Case, async: true

  alias Data.Vocabulary

  doctest Vocabulary

  test "priv/vocabulary.json is what the module says — run `mix aq.vocabulary` if not" do
    assert File.read!(Vocabulary.json_path()) == Vocabulary.to_json(),
           "apps/data/priv/vocabulary.json is out of date: run `mix aq.vocabulary`"
  end

  test "the exported keys are sorted and every list keeps its order" do
    decoded = Jason.decode!(File.read!(Vocabulary.json_path()), objects: :ordered_objects)
    keys = Enum.map(decoded.values, fn {key, _values} -> key end)

    assert keys == Enum.sort(keys)

    for {key, values} <- decoded.values do
      assert values == Map.fetch!(Vocabulary.all(), String.to_existing_atom(key))
    end
  end

  test "no list repeats a value" do
    for {name, values} <- Vocabulary.all() do
      assert values == Enum.uniq(values), "#{name} repeats a value"
    end
  end

  # The lists the plan fixes word for word (PLAN §1, §6.2, §9). A change here
  # is a change to the frontend's packages/core in the same breath.
  test "states and stages, in their order" do
    assert Vocabulary.lead_states() == ~w(todo in_progress on_hold done)

    assert Vocabulary.stage_kinds() ==
             ~w(inbound applied seen screening assessment interview ai_interview final offer negotiation contract)

    assert Vocabulary.task_states() == ~w(draft todo in_progress on_hold done closed)

    assert Vocabulary.approval_states() ==
             ~w(draft pending approved changes_requested rejected withdrawn expired)
  end

  # AQ-02 §7.6, word for word and in order: both repos build to it.
  test "the board's lists, in their order" do
    assert Vocabulary.task_priorities() == ~w(low high urgent)
    assert Vocabulary.task_close_reasons() == ~w(not_needed wont_do duplicate withdrawn)
    assert Vocabulary.task_customer_access() == ~w(none shared assigned)
    assert Vocabulary.task_relation_kinds() == ~w(relates_to blocks duplicates)
    assert Vocabulary.task_sources() == ~w(staff customer)
    assert Vocabulary.task_reminders() == [0, 60, 1440]

    assert Vocabulary.task_history_fields() ==
             ~w(created title description state stage priority due reminder team customer profile
                customer_access private assignees watchers checklist step link relation file archived)

    refute Map.has_key?(Vocabulary.all(), :task_statuses)
  end

  # AQ-03 §7.1, word for word and in order: both repos build to it.
  test "the job pool's lists, in their order" do
    assert Vocabulary.job_sources() ==
             ~w(linkedin upwork indeed yc_waas wellfound fiverr greenhouse lever ashby workable
                company_site email other)

    assert Vocabulary.job_origins() == ~w(manual extension email import)
    assert Vocabulary.job_statuses() == ~w(open closed unknown)
    assert Vocabulary.job_close_reasons() == ~w(filled expired withdrawn other)
    assert Vocabulary.remote_scopes() == ~w(global region country_list unknown)

    assert Vocabulary.regions() ==
             ~w(europe eu uk_ireland north_america us canada latam emea apac mena south_asia
                africa oceania)

    assert Vocabulary.visa_policies() == ~w(yes no existing_auth_only unknown)
    assert Vocabulary.durations() == ~w(lt_1m 1_3m 3_6m gt_6m)
    assert Vocabulary.comp_sources() == ~w(employer platform_estimate parsed_text)
    assert Vocabulary.equity_kinds() == ~w(options rsu profit_share unknown)

    assert Vocabulary.company_size_bands() ==
             ~w(1_10 11_50 51_200 201_500 501_1000 1001_5000 5001_plus)

    assert Vocabulary.upwork_experience_levels() == ~w(entry intermediate expert)
    assert Vocabulary.upwork_spent_bands() == ~w(none lt_1k 1k_10k 10k_100k 100k_1m gt_1m)

    assert Vocabulary.job_dismiss_reasons() ==
             ~w(skills money location seniority company already_known other)

    assert Vocabulary.suggestion_parts() ==
             ~w(skills engagement workplace money timezone seniority)

    # The channels' list stays as it is (QP3-3).
    assert Vocabulary.platforms() ==
             ~w(linkedin upwork indeed fiverr yc_waas wellfound email other)
  end

  # AQ-03B §5.1, word for word and in order: both repos build to it.
  test "the team levels and the share levels, in their order" do
    assert Vocabulary.peer_access() == ~w(hidden view edit)
    assert Vocabulary.share_levels() == ~w(summary details details_history)
  end

  # AQ-04A §5.5 and §4.0, word for word and in order: both repos build to it.
  test "the leads' lists and the roles, in their order" do
    assert Vocabulary.roles() == ~w(admin lead member customer)
    assert Vocabulary.team_member_roles() == ~w(lead member)

    assert Vocabulary.lead_event_kinds() ==
             ~w(saved applied stage_moved state_moved outcome_set reopened owner_changed
                pipeline_changed cv_set archived unarchived note_added task_created task_done
                follow_up_due follow_up_logged archive_warned labelled message_in message_out
                conversation_linked contact_linked contact_unlinked meeting_scheduled
                meeting_changed meeting_done meeting_cancelled classified approval_requested
                approval_decided approval_withdrawn)

    assert Vocabulary.lead_confirmations() == ~w(by_hand page_confirmation confirmation_email)
    assert Vocabulary.lead_priorities() == ~w(low high urgent)
    assert Vocabulary.bid_periods() == ~w(hour project)
    assert Vocabulary.lead_archive_reasons() == ~w(by_hand inactive)
    assert Vocabulary.event_actors() == ~w(user customer extension email system)
    assert Vocabulary.event_visibilities() == ~w(staff customer)
  end

  test "P4b's lists (AQ-04B §5.4), in their order" do
    assert Vocabulary.saved_view_screens() == ~w(tracker leads jobs board)

    assert Vocabulary.tracker_columns() ==
             ~w(applied title company source customer profile owner state outcome next
                last_activity money workplace engagement cv labels missing)

    assert Vocabulary.tracker_groups() == ~w(none state stage customer profile owner source)
    assert Vocabulary.board_lanes() == ~w(none customer profile owner source)
  end

  # AQ-05 §11.4, word for word and in order, in all three repos.
  test "P5's lists (AQ-05 §5.5), in their order" do
    assert Vocabulary.ext_sites() == ~w(linkedin upwork)
    assert Vocabulary.ext_page_kinds() == ~w(job search proposal confirmation thread other)
  end

  # AQ-06 §11.6, word for word and in order, in all three repos.
  test "P6's lists (AQ-06 §11.6), in their order" do
    assert Vocabulary.contact_sources() == ~w(manual email extension import)
    assert Vocabulary.contact_handle_kinds() == ~w(email linkedin upwork phone other)

    assert Vocabulary.contact_roles() ==
             ~w(recruiter hiring_manager interviewer client referrer other)

    assert Vocabulary.match_methods() ==
             ~w(by_hand headers thread_id sender_handle created_from_triage)

    assert Vocabulary.match_confidences() == ~w(sure likely)
    assert Vocabulary.message_directions() == ~w(in out)
    assert Vocabulary.message_from_kinds() == ~w(contact user customer text)
    assert Vocabulary.message_captures() == ~w(manual eml_upload extension forward oauth_sync)

    assert Vocabulary.message_classes() ==
             ~w(interested interview_invitation more_info rejection position_closed unsubscribe
                bounce general)

    assert Vocabulary.meeting_statuses() == ~w(scheduled done cancelled no_show)
    assert Vocabulary.meeting_sources() == ~w(manual email_invite extension)

    assert Vocabulary.meeting_kinds() ==
             ~w(screening technical assessment_review ai_interview final client_call other)

    assert Vocabulary.meeting_platforms() ==
             ~w(zoom google_meet teams upwork phone on_site other)
  end

  # AQ-07 §11.4, word for word and in order, in every repo.
  test "P7's lists (AQ-07 §11.4), in their order" do
    assert Vocabulary.approval_rules() == ~w(any all)
    assert Vocabulary.approval_needs() == ~w(customer team_lead both ad_hoc)
    assert Vocabulary.reviewer_slots() == ~w(customer team_lead user)
    assert Vocabulary.approval_decisions() == ~w(approved changes_requested rejected)
    assert Vocabulary.approval_effects() == ~w(none ready sent applied failed)

    assert Vocabulary.approval_kinds() ==
             ~w(reply proposal cv_for_job cover_letter rate asset profile_change other)
  end

  # AQ-08 §11.4, word for word and in order, in every repo.
  test "P8's lists (AQ-08 §11.4), in their order" do
    assert Vocabulary.delivery_channels() == ~w(push email extension)
    assert Vocabulary.delivery_states() == ~w(pending sent skipped failed)
    assert Vocabulary.delivery_skip_reasons() == ~w(read no_target preference_off)
    assert Vocabulary.push_apps() == ~w(team client)
    assert Vocabulary.notification_channels() == ~w(inapp push email extension digest)
    assert Vocabulary.delivery_channels() -- Vocabulary.notification_channels() == []
  end

  test "team roles are organisation roles" do
    assert Vocabulary.team_member_roles() -- Vocabulary.roles() == []
  end

  test "a custom stage needs a slug" do
    assert Vocabulary.custom_stage?("custom.portfolio_review")
    refute Vocabulary.custom_stage?("custom.")
    refute Vocabulary.custom_stage?("offer")
  end
end
