defmodule Data.Audit.AuditEvent do
  @moduledoc """
  One audit row (JH-01 §4.2): who, how, what, on what, before → after.
  The one place a `kind + id` pair is allowed (AutoCare §8a D3).
  """

  use Data.Schema

  alias Data.Accounts.User
  alias Data.Organisations.Organisation

  @vias ~w(web extension task system)a

  @type t :: %__MODULE__{}

  schema "audit_events" do
    field(:via, Ecto.Enum, values: @vias)
    field(:subject_kind, :string)
    field(:subject_id, :binary_id)
    field(:action, :string)
    field(:before, :map)
    field(:after, :map)
    field(:request_id, :string)
    field(:occurred_at, :utc_datetime_usec)
    # A human label for the subject (a name, a title), filled by `Core.Audit.Labels`.
    field(:subject_label, :string, virtual: true)

    belongs_to(:organisation, Organisation)
    belongs_to(:actor_user, User)
  end

  def vias, do: @vias

  def changeset(event, attrs) do
    event
    |> cast(attrs, [
      :organisation_id,
      :actor_user_id,
      :via,
      :subject_kind,
      :subject_id,
      :action,
      :before,
      :after,
      :request_id,
      :occurred_at
    ])
    |> validate_required([
      :organisation_id,
      :via,
      :subject_kind,
      :subject_id,
      :action,
      :occurred_at
    ])
    |> check_constraint(:via, name: :via_known)
    |> foreign_key_constraint(:organisation_id)
  end
end
