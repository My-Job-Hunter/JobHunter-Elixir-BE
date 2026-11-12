defmodule Data.Teams.TeamSettings do
  @moduledoc """
  A team's settings (AQ-01 §4.2; PLAN §3.4; AQ-03B §3.2), 1:1 with the team.

  Three **levels**, one per kind, decide what a member does with a
  teammate's item: `peer_tasks`, `peer_leads`, `peer_jobs`, each
  `Data.Vocabulary.peer_access/0` (`hidden · view · edit`), defaults
  `view · view · edit` (QT-4). Three toggles decide what the customer sees.
  """

  use Data.Schema

  @primary_key false

  @levels Data.Vocabulary.peer_access() |> Enum.map(&String.to_atom/1)

  @type t :: %__MODULE__{}

  @fields ~w(peer_tasks peer_leads peer_jobs customer_sees_staff_names
             customer_sees_conversations customer_sees_job_suggestions)a

  schema "team_settings" do
    field(:team_id, :binary_id, primary_key: true)
    field(:peer_tasks, Ecto.Enum, values: @levels, default: :view)
    field(:peer_leads, Ecto.Enum, values: @levels, default: :view)
    field(:peer_jobs, Ecto.Enum, values: @levels, default: :edit)
    field(:customer_sees_staff_names, :boolean, default: true)
    field(:customer_sees_conversations, :boolean, default: true)
    field(:customer_sees_job_suggestions, :boolean, default: false)

    timestamps()
  end

  @doc "The six settings, in the order the API answers them."
  def fields, do: @fields

  @doc "The code defaults, as a row that was never written."
  @spec defaults(binary()) :: t()
  def defaults(team_id), do: %__MODULE__{team_id: team_id}

  def changeset(settings, attrs) do
    settings
    |> cast(attrs, [:team_id | @fields])
    |> validate_required([:team_id | @fields])
    |> check_constraint(:peer_tasks, name: :peer_tasks_known)
    |> check_constraint(:peer_leads, name: :peer_leads_known)
    |> check_constraint(:peer_jobs, name: :peer_jobs_known)
    |> foreign_key_constraint(:team_id)
  end
end
