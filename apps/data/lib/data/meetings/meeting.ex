defmodule Data.Meetings.Meeting do
  @moduledoc """
  A lead's meeting (AQ-06 §5.3): its kind, where, when (UTC with the zone
  it was set in), its status, and `sequence`, the ICS file's revision. A
  reschedule moves the times and the sequence; it is never a status
  (QP6-15).
  """

  use Data.Schema

  alias Data.Accounts.User
  alias Data.Leads.Lead
  alias Data.Meetings.Attendee
  alias Data.Organisations.Organisation
  alias Data.Vocabulary

  @kinds Vocabulary.meeting_kinds() |> Enum.map(&String.to_atom/1)
  @platforms Vocabulary.meeting_platforms() |> Enum.map(&String.to_atom/1)
  @statuses Vocabulary.meeting_statuses() |> Enum.map(&String.to_atom/1)
  @sources Vocabulary.meeting_sources() |> Enum.map(&String.to_atom/1)

  @editable ~w(title meeting_kind platform join_url address notes_md)a

  @type t :: %__MODULE__{}

  schema "meetings" do
    field(:title, :string)
    field(:meeting_kind, Ecto.Enum, values: @kinds)
    field(:platform, Ecto.Enum, values: @platforms)
    field(:join_url, :string)
    field(:address, :string)
    field(:starts_at, :utc_datetime_usec)
    field(:ends_at, :utc_datetime_usec)
    field(:time_zone, :string)
    field(:status, Ecto.Enum, values: @statuses, default: :scheduled)
    field(:outcome_note, :string)
    field(:notes_md, :string)
    field(:source, Ecto.Enum, values: @sources, default: :manual)
    field(:sequence, :integer, default: 0)

    belongs_to(:organisation, Organisation)
    belongs_to(:lead, Lead)
    belongs_to(:created_by_user, User)
    has_many(:attendees, Attendee)

    timestamps()
  end

  @doc "What `PATCH /meetings/:id` may change: never the times (a reschedule) or the status (a verb)."
  def editable, do: @editable

  def changeset(meeting, attrs) do
    meeting
    |> cast(attrs, [
      :organisation_id,
      :lead_id,
      :starts_at,
      :ends_at,
      :time_zone,
      :status,
      :outcome_note,
      :source,
      :sequence,
      :created_by_user_id | @editable
    ])
    |> update_change(:title, &(&1 && String.trim(&1)))
    |> validate_required([
      :organisation_id,
      :lead_id,
      :title,
      :meeting_kind,
      :platform,
      :starts_at,
      :ends_at,
      :time_zone
    ])
    |> validate_length(:title, max: 200)
    |> validate_length(:join_url, max: 2000)
    |> validate_length(:address, max: 500)
    |> validate_length(:notes_md, max: 20_000)
    |> validate_length(:outcome_note, max: 2000)
    |> validate_link(:join_url)
    |> validate_zone()
    |> validate_order()
    |> check_constraint(:meeting_kind, name: :meeting_kind_known)
    |> check_constraint(:platform, name: :platform_known)
    |> check_constraint(:status, name: :status_known)
    |> check_constraint(:source, name: :source_known)
    |> check_constraint(:ends_at, name: :ends_after_starts, message: "must be after it starts")
    |> check_constraint(:title, name: :title_present, message: "can't be blank")
  end

  defp validate_order(changeset) do
    starts = get_field(changeset, :starts_at)
    ends = get_field(changeset, :ends_at)

    if starts && ends && DateTime.compare(ends, starts) != :gt,
      do: add_error(changeset, :ends_at, "must be after it starts"),
      else: changeset
  end

  defp validate_zone(changeset) do
    validate_change(changeset, :time_zone, fn :time_zone, zone ->
      case DateTime.now(zone) do
        {:ok, _now} -> []
        _unknown -> [time_zone: "is not a known IANA time zone"]
      end
    end)
  end

  defp validate_link(changeset, field) do
    validate_change(changeset, field, fn ^field, url ->
      case URI.new(url) do
        {:ok, %URI{scheme: scheme, host: host}}
        when scheme in ["http", "https"] and is_binary(host) and host != "" ->
          []

        _not_a_link ->
          [{field, "is not a link"}]
      end
    end)
  end
end
