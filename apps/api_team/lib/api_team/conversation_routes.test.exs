defmodule ApiTeam.ConversationRoutesTest do
  @moduledoc """
  AQ-06 §11.1 over HTTP, with the bodies of §11.6: contacts and the match
  (201, 409 `contact_exists` in the house shape), a lead's contacts,
  *Log message* (201, the **conversation**), `POST /eml` (201, then 200
  for the same file), triage, *Create job and lead* (201), *Classify*,
  meetings (201 with `clash`), the clash check, the ICS file, the Meetings
  page and the lead sheet's new members — each shape's exact keys.
  """

  use ApiTeam.TeamCase, async: true

  @contact ~w(can company created_by handles id is_do_not_contact leads location merged_into
              name notes_md source time_zone title)
  @message ~w(attachments body_html body_text can captured_via children classification deleted direction
              from id is_internal parent_id parent_missing sent_at to_text)
  @conversation ~w(channel gaps id ignored_at last_message_at leads messages participants platform
                   subject team)
  @meeting ~w(address attendees can clash ends_at id join_url lead meeting_kind notes_md outcome_note
              platform sequence source starts_at status time_zone title)

  setup do
    c = board_cast_fixture()
    juniper = company_fixture(c.org, name: "Juniper Edge")

    job =
      job_fixture(scope_for(c.fiza),
        team: c.backend,
        title: "Platform Engineer",
        company: juniper
      )

    lead =
      body(
        call(c.fiza, :post, "/v1/leads", %{job_id: job.id, profile_id: c.golang.id, as: "apply"})
      )

    Map.merge(c, %{juniper: juniper, lead: lead})
  end

  defp keys(map), do: map |> Map.keys() |> Enum.sort()

  defp mei(c) do
    call(c.fiza, :post, "/v1/contacts", %{
      name: "Mei Chen",
      title: "Talent Partner",
      company_id: c.juniper.id,
      handles: [
        %{kind: "email", value: "mei.chen@juniperedge.example"},
        %{kind: "linkedin", value: "https://www.linkedin.com/in/mei-chen-example/"}
      ]
    })
  end

  test "contacts: 201, the shape, the match, 409 contact_exists, the page, a lead's recruiters",
       c do
    created = mei(c)
    assert created.status == 201
    contact = body(created)
    assert keys(contact) == Enum.sort(@contact)
    assert [%{"kind" => "email"}, %{"kind" => "linkedin"}] = contact["handles"]

    dup =
      call(c.fiza, :post, "/v1/contacts", %{
        name: "Someone",
        handles: [%{kind: "linkedin", value: "linkedin.com/in/mei-chen-example"}]
      })

    assert dup.status == 409

    assert body(dup)["error"] == %{
             "code" => "contact_exists",
             "message" => "That LinkedIn is Mei Chen's already.",
             "details" => %{"contact_id" => contact["id"], "name" => "Mei Chen"}
           }

    match =
      body(
        call(c.fiza, :post, "/v1/contacts/match", %{
          name: "Mei Chen",
          company_name: "Juniper Edge",
          handles: []
        })
      )

    assert keys(match) == ~w(answer candidates contact)
    assert match["answer"] == "possible" and match["contact"] == nil

    page = body(call(c.muaz, :get, "/v1/contacts?q=mei"))
    assert keys(page) == ~w(items next_cursor)
    assert [row] = page["items"]
    refute Map.has_key?(row, "leads")

    recruiters =
      body(
        call(c.fiza, :post, "/v1/leads/#{c.lead["id"]}/contacts", %{
          contact_id: contact["id"],
          role: "recruiter"
        })
      )

    assert [%{"role" => "recruiter", "contact" => %{"name" => "Mei Chen", "leads_count" => 1}}] =
             recruiters

    sheet = body(call(c.fiza, :get, "/v1/leads/#{c.lead["id"]}"))
    assert [%{"role" => "recruiter"}] = sheet["recruiters"]

    assert sheet["tabs"] == %{
             "email" => 0,
             "linkedin" => 0,
             "upwork" => 0,
             "other" => 0,
             "meetings" => 0,
             "approvals" => 0
           }

    assert sheet["banner"] == nil

    assert call(c.fiza, :delete, "/v1/leads/#{c.lead["id"]}/contacts/#{contact["id"]}").status ==
             204

    merge =
      call(c.muaz, :post, "/v1/contacts/#{contact["id"]}/merge", %{into_contact_id: contact["id"]})

    assert merge.status == 403 and
             body(merge)["error"]["message"] == "Only a team lead can merge contacts."
  end

  test "Log message: 201 and the conversation's tree; PATCH; DELETE 204; the message's exact keys",
       c do
    contact = body(mei(c))

    first =
      call(c.fiza, :post, "/v1/messages", %{
        lead_id: c.lead["id"],
        platform: "email",
        subject: "Platform Engineer role",
        direction: "in",
        from: %{kind: "contact", contact_id: contact["id"]},
        sent_at: "2026-11-02T02:15:00Z",
        body_md: "Are you open to a call?"
      })

    assert first.status == 201
    conv = body(first)
    assert keys(conv) == Enum.sort(@conversation)
    [root] = conv["messages"]
    assert keys(root) == Enum.sort(@message)

    assert root["from"] == %{
             "kind" => "contact",
             "contact" => %{"id" => contact["id"], "name" => "Mei Chen"},
             "person" => nil,
             "text" => nil
           }

    assert root["can"] == %{"edit" => true, "delete" => true, "classify" => true, "reply" => true}

    reply =
      body(
        call(c.fiza, :post, "/v1/messages", %{
          conversation_id: conv["id"],
          direction: "out",
          from: %{kind: "user"},
          sent_at: "2026-11-02T05:00:00Z",
          body_md: "Yes, Thursday works",
          parent_message_id: root["id"]
        })
      )

    [%{"children" => [child]}] = reply["messages"]
    assert child["parent_id"] == root["id"]

    edited =
      call(c.fiza, :patch, "/v1/messages/#{child["id"]}", %{body_md: "Yes, Thursday 10:00 works"})

    assert edited.status == 200
    assert call(c.fiza, :delete, "/v1/messages/#{child["id"]}").status == 204

    listed = body(call(c.fiza, :get, "/v1/leads/#{c.lead["id"]}/conversations"))
    assert [%{"messages" => [%{"children" => [%{"deleted" => true}]}]}] = listed

    sheet = body(call(c.fiza, :get, "/v1/leads/#{c.lead["id"]}"))
    assert sheet["tabs"]["email"] == 1

    classified =
      body(
        call(c.fiza, :post, "/v1/messages/#{root["id"]}/classify", %{
          class: "interview_invitation"
        })
      )

    assert keys(classified) == ~w(lead message next)
    assert classified["next"] == "schedule_meeting"
  end

  test "POST /eml: 201 then 200 for the same file; triage, Create job and lead 201", c do
    {:ok, media, _target} =
      Core.Media.create(
        scope_for(c.fiza),
        %{
          "media_kind" => "eml",
          "content_type" => "message/rfc822",
          "byte_count" => 10,
          "original_filename" => "t.eml"
        },
        "/media"
      )

    bytes = File.read!(Path.expand("../../../core/priv/eml/thread-1.eml", __DIR__))
    :ok = Core.Media.store(scope_for(c.fiza), media.id, bytes)
    {:ok, _} = Core.Media.confirm(scope_for(c.fiza), media.id, %{}, DateTime.utc_now())

    landed = call(c.fiza, :post, "/v1/eml", %{media_id: media.id, team_id: c.backend.id})
    assert landed.status == 201
    answer = body(landed)
    assert keys(answer) == ~w(added already conversation landed leads)
    assert answer["landed"] == "triage" and answer["added"] == 1

    again = call(c.fiza, :post, "/v1/eml", %{media_id: media.id, team_id: c.backend.id})
    assert again.status == 200 and body(again)["already"] == 1

    triage = body(call(c.muaz, :get, "/v1/triage?team_id=#{c.backend.id}"))
    assert keys(triage) == ~w(items team)
    [item] = triage["items"]
    assert keys(item) == ~w(candidates conversation first_message)
    assert item["first_message"]["children"] == []

    no_link =
      call(c.fiza, :post, "/v1/conversations/#{item["conversation"]["id"]}/create-lead", %{
        profile_id: c.golang.id,
        job: %{title: "Platform Engineer", source: "email"}
      })

    assert no_link.status == 422 and
             body(no_link)["error"]["details"] == %{"job.url" => ["Add the job's link."]}

    made =
      call(c.fiza, :post, "/v1/conversations/#{item["conversation"]["id"]}/create-lead", %{
        profile_id: c.golang.id,
        job: %{
          url: "https://juniperedge.example/careers/platform-engineer-2",
          title: "Platform Engineer II"
        }
      })

    assert made.status == 201
    made = body(made)
    assert keys(made) == ~w(conversation lead)
    assert made["lead"]["stage"]["key"] == "recruiter_contact"
    assert [%{"match_method" => "created_from_triage"}] = made["conversation"]["leads"]

    assert body(call(c.fiza, :get, "/v1/triage?team_id=#{c.backend.id}"))["items"] == []
  end

  test "meetings: 201 with clash; the clash check; the verbs; the ICS; the page; the sheet's banner and Next",
       c do
    m =
      call(c.fiza, :post, "/v1/leads/#{c.lead["id"]}/meetings", %{
        title: "Technical interview",
        meeting_kind: "technical",
        platform: "google_meet",
        join_url: "https://meet.google.com/abc-defg-hij",
        starts_at: "2026-11-18T09:00:00Z",
        ends_at: "2026-11-18T10:00:00Z",
        time_zone: "Europe/Berlin",
        attendees: [%{user_id: c.fiza.id}, %{customer: true}],
        move_to_stage: "technical_1"
      })

    assert m.status == 201
    meeting = body(m)
    assert keys(meeting) == Enum.sort(@meeting)
    assert keys(meeting["lead"]) == ~w(company customer id profile title)
    assert meeting["clash"] == nil

    clash =
      body(
        call(c.fiza, :post, "/v1/meetings/clash", %{
          lead_id: c.lead["id"],
          starts_at: "2026-11-25T09:00:00Z",
          ends_at: "2026-11-25T10:00:00Z",
          meeting_kind: "final"
        })
      )

    assert clash == %{
             "clash" => nil,
             "stage_offer" => %{
               "key" => "final",
               "name" => "Final / culture",
               "words" => "Move to Final / culture?"
             }
           }

    ics = call(c.fiza, :get, "/v1/meetings/#{meeting["id"]}/ics")
    assert ics.status == 200
    assert ["text/calendar; charset=utf-8"] = Plug.Conn.get_resp_header(ics, "content-type")
    assert ics.resp_body =~ "UID:#{meeting["id"]}@autoqare"

    moved =
      body(
        call(c.fiza, :post, "/v1/meetings/#{meeting["id"]}/reschedule", %{
          starts_at: "2026-11-19T09:00:00Z",
          ends_at: "2026-11-19T10:00:00Z"
        })
      )

    assert moved["sequence"] == 1

    page = body(call(c.muaz, :get, "/v1/meetings?team_id=#{c.backend.id}"))
    assert [%{"id" => id}] = page["items"]
    assert id == meeting["id"]
    assert [%{"id" => ^id}] = body(call(c.fiza, :get, "/v1/leads/#{c.lead["id"]}/meetings"))

    sheet = body(call(c.fiza, :get, "/v1/leads/#{c.lead["id"]}"))
    assert sheet["banner"]["id"] == id
    assert %{"kind" => "meeting", "meeting_id" => ^id, "task_id" => nil} = sheet["next"]

    cancelled =
      body(call(c.fiza, :post, "/v1/meetings/#{id}/cancel", %{outcome_note: "Role paused"}))

    assert cancelled["status"] == "cancelled"

    again = call(c.fiza, :post, "/v1/meetings/#{id}/done", %{})
    assert again.status == 422

    assert body(again)["error"]["details"] == %{
             "status" => ["This meeting is already cancelled."]
           }
  end
end
