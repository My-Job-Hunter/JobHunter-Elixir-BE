defmodule Core.Retention.ConversationsTest do
  @moduledoc """
  AQ-06 §10 (QP4b-5's promise, QP6-23): a purged lead takes its meetings
  and their attendees, its contact links, and **the conversations only it
  held** with their messages and files (the rows, then the bytes through
  `Core.Storage`); a conversation another live lead holds stays, losing
  only the link; contacts are never purged; the fingerprint as before.
  """

  use Core.CoreCase, async: true

  import Ecto.Query, only: [from: 2]

  alias Core.Contacts.LeadLinks
  alias Core.Conversations.Inbox
  alias Core.Retention

  @t0 ~U[2026-11-01 09:00:00.000000Z]

  defp day(n), do: DateTime.add(@t0, n * 86_400, :second)

  setup do
    c = board_cast_fixture()
    fiza = scope_for(c.fiza)
    job = job_fixture(fiza, team: c.backend, title: "Platform Engineer")

    Repo.update_all(from(j in Data.Jobs.Job, where: j.id == ^job.id),
      set: [last_activity_at: @t0, first_seen_at: @t0]
    )

    quiet = lead_fixture(fiza, job: job, profile: c.golang, as: :apply, last_activity_at: @t0)
    live = lead_fixture(fiza, team: c.backend, profile: c.golang, as: :apply)
    %{leads: 1} = Retention.archive(day(90))

    mei =
      contact_fixture(fiza, name: "Mei Chen", handles: [{:email, "mei.chen@juniperedge.example"}])

    {:ok, _} =
      LeadLinks.link(
        fiza,
        quiet.id,
        %{"contact_id" => mei.id, "role" => "recruiter"},
        day(91)
      )

    meeting = meeting_fixture(fiza, lead: quiet, attendees: [{:contact, mei}, :customer])

    media = eml_media(fiza, "thread-2.eml")

    {:ok, {:created, %{conversation: sole}}} =
      Inbox.eml(
        fiza,
        %{"media_id" => media.id, "team_id" => c.backend.id, "lead_id" => quiet.id},
        day(91)
      )

    shared = conversation_fixture(fiza, lead: quiet)

    {:ok, :linked} =
      Data.Conversations.link(%{
        conversation_id: shared.id,
        lead_id: live.id,
        match_method: :by_hand,
        confidence: :sure
      })

    _kept = message_fixture(fiza, conversation: shared, contact: mei)

    Map.merge(c, %{
      quiet: quiet,
      live: live,
      mei: mei,
      meeting: meeting,
      sole: sole,
      shared: shared,
      eml: media
    })
  end

  test "the purge takes the meetings, the links and the sole conversation with its files; the shared one stays",
       c do
    files = Data.Conversations.media_of([c.sole.id])
    assert length(files) == 2
    assert Enum.all?(files, &match?({:ok, _bytes}, Core.Storage.fetch(&1.storage_key)))

    assert %{leads: 1} = Retention.purge(day(180))

    assert Repo.get(Data.Leads.Lead, c.quiet.id) == nil
    assert Repo.get(Data.Meetings.Meeting, c.meeting.id) == nil
    assert Repo.all(from(a in Data.Meetings.Attendee, where: a.meeting_id == ^c.meeting.id)) == []
    assert Repo.all(from(l in Data.Contacts.LeadContact, where: l.lead_id == ^c.quiet.id)) == []

    assert Repo.get(Data.Conversations.Conversation, c.sole.id) == nil

    assert Repo.all(from(m in Data.Conversations.Message, where: m.conversation_id == ^c.sole.id)) ==
             []

    for f <- files do
      assert Repo.get(Data.Files.Media, f.id) == nil
      assert {:error, _gone} = Core.Storage.fetch(f.storage_key)
    end

    assert Data.Conversations.lead_ids(c.shared.id) == [c.live.id]

    assert Repo.aggregate(
             from(m in Data.Conversations.Message, where: m.conversation_id == ^c.shared.id),
             :count
           ) == 1

    assert Data.Contacts.get(c.org.id, c.mei.id)
    assert [_print] = Repo.all(Data.Leads.Fingerprint)
    assert %{leads: 0} = Retention.purge(day(180))
  end
end
