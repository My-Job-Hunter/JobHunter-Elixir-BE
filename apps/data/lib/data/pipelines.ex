defmodule Data.Pipelines do
  @moduledoc """
  The organisation's pipelines (AQ-04A §5.1, §9): versions and their stages.
  Storage only: the rules of an edit, who may make one, and `ensure` are
  `Core.Leads.Pipelines`'s.

  **The defaults are code, not rows** (§9.1, PLAN §17): `defaults/1` is the
  version 1 of each pipeline. They sit here, beside the rows they become,
  so the test fixtures (which cannot name `core`) build the same stages;
  `Core.Leads.Pipelines.defaults/1` answers them to everyone else.
  """

  import Ecto.Query, warn: false

  alias Data.Pipelines.{Stage, Version}
  alias Data.Repo

  @employment [
    {"recruiter_contact", "Recruiter contact", :inbound},
    {"applied", "Applied", :applied},
    {"recruiter_screen", "Recruiter screen", :screening},
    {"assessment", "Assessment / take-home", :assessment},
    {"technical_1", "Technical interview 1", :interview},
    {"technical_2", "Technical interview 2", :interview},
    {"ai_interview", "AI interview", :ai_interview},
    {"final", "Final / culture", :final},
    {"offer", "Offer", :offer},
    {"negotiation", "Negotiation", :negotiation}
  ]

  @freelance [
    {"invited", "Invited by client", :inbound},
    {"proposal_sent", "Proposal sent", :applied},
    {"viewed", "Viewed by client", :seen},
    {"shortlisted", "Messaged / shortlisted", :screening},
    {"test_task", "Paid test task", :assessment},
    {"interview", "Interview", :interview},
    {"offer", "Offer", :offer},
    {"contract_started", "Contract started", :contract}
  ]

  @doc "Version 1 of a pipeline (§9.1), as `[%{key, name, kind, anchor_kind}]` in order."
  @spec defaults(:employment | :freelance) :: [map()]
  def defaults(:employment), do: stages(@employment)
  def defaults(:freelance), do: stages(@freelance)

  defp stages(rows),
    do: for({key, name, kind} <- rows, do: %{key: key, name: name, kind: kind, anchor_kind: nil})

  # ── Reads ───────────────────────────────────────────────────────────────────

  @doc "The live (newest) version of a pipeline, with its stages in order; `nil` before `ensure`."
  @spec live(binary(), atom()) :: Version.t() | nil
  def live(organisation_id, key) do
    from(v in Version,
      where: v.organisation_id == ^organisation_id and v.pipeline_key == ^key,
      order_by: [desc: v.number],
      limit: 1,
      preload: [:stages]
    )
    |> Repo.one()
  end

  @doc "A version by id, with its stages."
  @spec get_version(binary()) :: Version.t() | nil
  def get_version(id), do: Version |> Repo.get(id) |> Repo.preload(:stages)

  @doc "Versions by id, with their stages: `%{id => version}`."
  @spec versions([binary()]) :: %{binary() => Version.t()}
  def versions([]), do: %{}

  def versions(ids) do
    from(v in Version, where: v.id in ^Enum.uniq(ids), preload: [:stages])
    |> Repo.all()
    |> Map.new(&{&1.id, &1})
  end

  @doc "Every stage of every version of a pipeline, newest version first: the keys ever used and the retired columns."
  @spec all_stages(binary(), atom()) :: [Stage.t()]
  def all_stages(organisation_id, key) do
    from(s in Stage,
      join: v in assoc(s, :pipeline_version),
      where: v.organisation_id == ^organisation_id and v.pipeline_key == ^key,
      order_by: [desc: v.number, asc: s.position],
      preload: [pipeline_version: v]
    )
    |> Repo.all()
  end

  # ── Writes ──────────────────────────────────────────────────────────────────

  @doc """
  Writes a version with its stages (`[%{key, name, kind, anchor_kind}]`, in
  order). The caller holds the transaction.
  """
  @spec create_version(map(), [map()]) :: {:ok, Version.t()} | {:error, Ecto.Changeset.t()}
  def create_version(attrs, stages) do
    with {:ok, version} <- %Version{} |> Version.changeset(attrs) |> Repo.insert(),
         :ok <- insert_stages(version, stages) do
      {:ok, Repo.preload(version, :stages, force: true)}
    end
  end

  defp insert_stages(version, stages) do
    stages
    |> Enum.with_index(1)
    |> Enum.reduce_while(:ok, fn {stage, position}, :ok ->
      attrs =
        stage |> Map.new() |> Map.merge(%{pipeline_version_id: version.id, position: position})

      case %Stage{} |> Stage.changeset(attrs) |> Repo.insert() do
        {:ok, _stage} -> {:cont, :ok}
        {:error, changeset} -> {:halt, {:error, changeset}}
      end
    end)
  end

  @doc """
  Takes a transaction-scoped lock on an organisation's pipeline, so two
  saves or two `ensure`s cannot both write the same number.
  """
  @spec lock(binary(), atom()) :: :ok
  def lock(organisation_id, key) do
    Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
      "pipeline:#{organisation_id}:#{key}"
    ])

    :ok
  end
end
