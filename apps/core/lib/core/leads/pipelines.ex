defmodule Core.Leads.Pipelines do
  @moduledoc """
  The organisation's two pipelines (AQ-04A §9, QP4a-2, QP4a-3): *Employment*
  and *Freelance*, versioned, one set for every team.

  - **The defaults are code** (§9.1): `defaults/1`. `ensure/2` writes version
    1 of each the first time the organisation needs it — at the bootstrap,
    else on the first read — and is idempotent (an advisory lock keeps two
    first reads from both writing).
  - **A save is a new version** (§9.2): the whole list as it now stands.
    Leads keep the version they started on; new leads, and leads moved with
    *Change pipeline*, use the newest.
  - **The rules of a save**: every stage named; the engine stages keep the
    engine's order (`stage_kinds`) and their kinds; a custom stage sits
    between its anchor and the next engine stage, at most 6 per pipeline
    (mCart's cap); the pipeline keeps its `applied` stage; a stage sent
    without a `key` is a new custom stage, whose key is made from its name
    and never one the pipeline used before.
  - **A stage's colour comes from its kind**, worked out by the frontend;
    nothing is stored.

  Reading is every staff member's; saving a team lead's (of any team) or the
  system admin's: "Only a team lead can change a pipeline."
  """

  alias Core.Access
  alias Core.Audit
  alias Data.Pipelines, as: Store
  alias Data.Pipelines.{Stage, Version}
  alias Data.Repo
  alias Data.Scope

  @keys [:employment, :freelance]
  @max_custom 6
  @engine Stage.engine_kinds()

  @doc "The pipelines' keys, as atoms."
  def keys, do: @keys

  @doc "Version 1 of a pipeline (§9.1): `[%{key, name, kind, anchor_kind}]`."
  @spec defaults(atom()) :: [map()]
  def defaults(key) when key in @keys, do: Store.defaults(key)

  @doc "The pipeline's name, as the vocabulary's label reads: *Employment*, *Freelance*."
  def name(key), do: key |> to_string() |> String.capitalize()

  # ── Ensure ──────────────────────────────────────────────────────────────────

  @doc "Version 1 of each pipeline the organisation does not have yet. Idempotent."
  @spec ensure(Scope.t(), DateTime.t()) :: :ok
  def ensure(%Scope{} = scope, %DateTime{} = now) do
    org_id = Scope.organisation_id(scope)

    {:ok, _done} = Repo.transaction(fn -> Enum.each(@keys, &ensure_one(org_id, &1, now)) end)
    :ok
  end

  defp ensure_one(org_id, key, now) do
    :ok = Store.lock(org_id, key)

    if is_nil(Store.live(org_id, key)) do
      attrs = %{organisation_id: org_id, pipeline_key: key, number: 1, inserted_at: now}
      {:ok, _version} = Store.create_version(attrs, defaults(key))
    end
  end

  # ── Reads ───────────────────────────────────────────────────────────────────

  @doc "The live version of a pipeline, ensured on the first read."
  @spec live(Scope.t(), atom()) :: Version.t()
  def live(%Scope{} = scope, key) when key in @keys do
    case Store.live(Scope.organisation_id(scope), key) do
      nil ->
        :ok = ensure(scope, Core.Clock.now())
        Store.live(Scope.organisation_id(scope), key)

      version ->
        version
    end
  end

  @doc "`GET /pipelines`: the live version of both, as `pipeline` shapes."
  @spec list(Scope.t()) :: {:ok, [map()]} | {:error, term()}
  def list(%Scope{} = scope) do
    with :ok <- Access.why_not(scope, :read, {:pipeline, nil}),
         do: {:ok, Enum.map(@keys, &view(scope, live(scope, &1)))}
  end

  @doc "`GET /pipelines/:key`."
  @spec get(Scope.t(), term()) :: {:ok, map()} | {:error, term()}
  def get(%Scope{} = scope, key) do
    with :ok <- Access.why_not(scope, :read, {:pipeline, key}),
         {:ok, key} <- key(key),
         do: {:ok, view(scope, live(scope, key))}
  end

  @doc "The `pipeline` shape (§8.3): `{key, name, version, stages, can_edit}`."
  @spec view(Scope.t(), Version.t()) :: map()
  def view(%Scope{} = scope, %Version{} = version) do
    %{
      key: version.pipeline_key,
      name: name(version.pipeline_key),
      version: version.number,
      stages: Enum.map(version.stages, &stage/1),
      can_edit: Access.can?(scope, :edit, {:pipeline, version.pipeline_key})
    }
  end

  @doc "The `stage` shape (§8.3): `{key, name, kind, anchor_kind, position}`."
  @spec stage(Stage.t() | nil) :: map() | nil
  def stage(nil), do: nil

  def stage(%Stage{} = s),
    do: %{
      key: s.key,
      name: s.name,
      kind: s.kind,
      anchor_kind: s.anchor_kind,
      position: s.position
    }

  defp key(key) do
    case Enum.find(@keys, &(to_string(&1) == to_string(key))) do
      nil -> {:error, :not_found}
      key -> {:ok, key}
    end
  end

  # ── Save ────────────────────────────────────────────────────────────────────

  @doc """
  `PUT /pipelines/:key {stages: [{key?, name, kind, anchor_kind?}]}`: a new
  version, audited (`pipeline_saved`). Answers the new `pipeline`.
  """
  @spec save(Scope.t(), term(), map(), DateTime.t()) :: {:ok, map()} | {:error, term()}
  def save(%Scope{} = scope, key, params, %DateTime{} = now) do
    with {:ok, key} <- key(key),
         :ok <- Access.why_not(scope, :edit, {:pipeline, key}),
         {:ok, rows} <- rows(params) do
      live = live(scope, key)

      fn -> write(scope, key, live, rows, now) end
      |> Repo.transaction()
      |> case do
        {:ok, version} -> {:ok, view(scope, Store.get_version(version.id))}
        error -> error
      end
    end
  end

  defp rows(%{"stages" => stages}) when is_list(stages) and stages != [],
    do: {:ok, Enum.map(stages, &stringify/1)}

  defp rows(params) when is_map(params) do
    case Map.get(params, :stages) do
      stages when is_list(stages) and stages != [] -> {:ok, Enum.map(stages, &stringify/1)}
      _none -> invalid("stages", "is a list of the stages, in order")
    end
  end

  defp write(scope, key, live, rows, now) do
    org_id = Scope.organisation_id(scope)
    :ok = Store.lock(org_id, key)
    live = Store.live(org_id, key) || live
    used = org_id |> Store.all_stages(key) |> Enum.map(& &1.key) |> MapSet.new()

    with {:ok, stages} <- resolve(rows, live, used),
         :ok <- validate(stages),
         {:ok, version} <-
           Store.create_version(
             %{
               organisation_id: org_id,
               pipeline_key: key,
               number: live.number + 1,
               created_by_user_id: Scope.user_id(scope),
               inserted_at: now
             },
             stages
           ) do
      {:ok, _event} =
        Audit.record(scope, "pipeline_saved", version,
          before: %{number: live.number, stages: Enum.map(live.stages, & &1.key)},
          after: %{number: version.number, stages: Enum.map(stages, & &1.key)},
          now: now
        )

      version
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  # Each row as a stage: a kept stage by its key (its kind and anchor are the
  # live version's), a new one custom, with a fresh key.
  defp resolve(rows, live, used) do
    by_key = Map.new(live.stages, &{&1.key, &1})

    rows
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, [], used}, fn {row, i}, {:ok, acc, used} ->
      case resolve_row(row, i, by_key, used) do
        {:ok, stage} -> {:cont, {:ok, [stage | acc], MapSet.put(used, stage.key)}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, stages, _used} -> {:ok, Enum.reverse(stages)}
      error -> error
    end
  end

  defp resolve_row(row, i, by_key, used) do
    name = row["name"] |> to_string() |> String.trim()

    cond do
      name == "" ->
        invalid("stages.#{i}.name", "can't be blank")

      String.length(name) > 60 ->
        invalid("stages.#{i}.name", "should be at most 60 characters")

      is_binary(row["key"]) and row["key"] != "" ->
        kept(row, i, name, Map.get(by_key, row["key"]))

      true ->
        added(row, i, name, used)
    end
  end

  defp kept(_row, i, _name, nil),
    do: invalid("stages.#{i}.key", "is not a stage of this pipeline")

  defp kept(row, i, name, %Stage{} = stage) do
    if is_nil(row["kind"]) or to_string(row["kind"]) == to_string(stage.kind),
      do: {:ok, %{key: stage.key, name: name, kind: stage.kind, anchor_kind: stage.anchor_kind}},
      else: invalid("stages.#{i}.kind", "can't change: remove the stage and add another")
  end

  # Only a custom stage is added, after an engine stage (§9.2).
  defp added(row, i, name, used) do
    with :ok <- custom(row, i),
         {:ok, anchor} <- anchor(row["anchor_kind"], i) do
      {:ok, %{key: fresh_key(name, used), name: name, kind: :custom, anchor_kind: anchor}}
    end
  end

  defp custom(%{"kind" => kind}, _i) when kind in ["custom", nil], do: :ok
  defp custom(_row, i), do: invalid("stages.#{i}.kind", "only a custom stage can be added")

  defp anchor(value, i) do
    case Enum.find(@engine, &(to_string(&1) == to_string(value))) do
      nil -> invalid("stages.#{i}.anchor_kind", "is the engine stage it follows")
      kind -> {:ok, kind}
    end
  end

  @doc false
  # A slug of the name, never a key the pipeline used before (`_2`, `_3`…).
  def fresh_key(name, used) do
    base =
      name
      |> String.downcase()
      |> String.normalize(:nfd)
      |> String.replace(~r/[^a-z0-9]+/, "_")
      |> String.trim("_")
      |> then(&if(&1 =~ ~r/^[a-z]/, do: &1, else: "stage_" <> &1))
      |> String.trim_trailing("_")
      |> String.slice(0, 36)
      |> String.trim_trailing("_")

    Stream.iterate(1, &(&1 + 1))
    |> Stream.map(&if(&1 == 1, do: base, else: "#{base}_#{&1}"))
    |> Enum.find(&(not MapSet.member?(used, &1)))
  end

  # The engine's order, the anchors, the cap, the `applied` stage, the names.
  defp validate(stages) do
    cond do
      Enum.count(stages, &(&1.kind == :custom)) > @max_custom ->
        invalid("stages", "can hold at most #{@max_custom} custom stages")

      not Enum.any?(stages, &(&1.kind == :applied)) ->
        invalid("stages", "must keep the pipeline's applied stage")

      not engine_order?(stages) ->
        invalid("stages", "must keep the engine stages in their order")

      not anchored?(stages) ->
        invalid("stages", "must keep each custom stage after the stage it follows")

      length(Enum.uniq_by(stages, &String.downcase(&1.name))) != length(stages) ->
        invalid("stages", "can't have two stages with the same name")

      true ->
        :ok
    end
  end

  defp engine_order?(stages) do
    ranks =
      for %{kind: kind} <- stages, kind != :custom, do: Enum.find_index(@engine, &(&1 == kind))

    ranks == Enum.sort(ranks)
  end

  # A custom stage's nearest engine stage before it is of its anchor's kind.
  defp anchored?(stages) do
    stages
    |> Enum.reduce_while(nil, fn
      %{kind: :custom, anchor_kind: anchor}, last ->
        if last == anchor, do: {:cont, last}, else: {:halt, :broken}

      %{kind: kind}, _last ->
        {:cont, kind}
    end)
    |> Kernel.!=(:broken)
  end

  defp stringify(row) when is_map(row), do: Map.new(row, fn {k, v} -> {to_string(k), v} end)
  defp stringify(_row), do: %{}

  defp invalid(field, message), do: {:error, {:invalid, %{field => [message]}}}
end
