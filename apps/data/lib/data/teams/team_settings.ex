defmodule Data.Teams.TeamSettings do
  @moduledoc """
  A team's six visibility toggles (JH-01 §4.2; PLAN §3.4), 1:1 with the team.
  """

  use Data.Schema

  @primary_key false

  @type t :: %__MODULE__{}

  @fields ~w(members_see_peer_tasks members_see_peer_leads members_move_peer_leads
             customer_sees_staff_names customer_sees_conversations customer_sees_job_suggestions)a

  schema "team_settings" do
    field(:team_id, :binary_id, primary_key: true)
    field(:members_see_peer_tasks, :boolean, default: false)
    field(:members_see_peer_leads, :boolean, default: true)
    field(:members_move_peer_leads, :boolean, default: false)
    field(:customer_sees_staff_names, :boolean, default: true)
    field(:customer_sees_conversations, :boolean, default: true)
    field(:customer_sees_job_suggestions, :boolean, default: false)

    timestamps()
  end

  @doc "The six toggles."
  def fields, do: @fields

  @doc "The code defaults, as a row that was never written."
  @spec defaults(binary()) :: t()
  def defaults(team_id), do: %__MODULE__{team_id: team_id}

  def changeset(settings, attrs) do
    settings
    |> cast(attrs, [:team_id | @fields])
    |> validate_required([:team_id | @fields])
    |> foreign_key_constraint(:team_id)
  end
end
