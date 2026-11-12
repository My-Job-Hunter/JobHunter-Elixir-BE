defmodule Core.Leads.Moves do
  @moduledoc """
  What every lead verb shares (AQ-04A §7): the write — the change, the
  caller's ledger rows and notices, the audit row, the realtime event, in
  the verb's transaction — and the small readings of a body: a stage of the
  lead's version by key, a reason, a day, where a lead stands in words.
  `Core.Leads.Act` and `Core.Leads.Change` are built on it.
  """

  alias Core.Audit
  alias Core.Leads
  alias Core.Leads.Words
  alias Core.Realtime
  alias Data.Leads, as: Store

  @doc """
  The change and what follows it: `tell.(moved)` writes the ledger rows and
  notices and answers `{told, realtime event}`; then the audit row with the
  before and after. Answers `{:ok, lead, events}` for
  `Core.Tasks.Write.commit/1`.
  """
  @type tell :: (map() -> {list(), String.t()})
  @spec change(Data.Scope.t(), map(), map(), String.t(), DateTime.t(), tell()) ::
          {:ok, map(), list()} | {:error, term()}
  def change(scope, lead, attrs, action, now, tell) do
    with {:ok, moved} <- Store.update(lead, attrs) do
      {told, event} = tell.(moved)
      moved = Store.reload(moved)

      {:ok, _audit} =
        Audit.record(scope, action, moved,
          before: Leads.snapshot(lead),
          after: Leads.snapshot(moved),
          now: now
        )

      {:ok, moved, [told, Realtime.lead_events(event, moved)]}
    end
  end

  @doc "A stage of the version by key, or `default` when none is sent (`{:missing, [:stage]}` without one)."
  @spec stage_in(map(), term(), map() | nil) :: {:ok, map()} | {:error, term()}
  def stage_in(version, key, default) do
    case Leads.blank(key) do
      nil when is_nil(default) -> {:error, {:missing, [:stage]}}
      nil -> {:ok, default}
      key -> stage_by_key(version, key)
    end
  end

  defp stage_by_key(version, key) do
    case Enum.find(version.stages, &(&1.key == to_string(key))) do
      nil -> Leads.invalid("stage", "is not a stage of this lead's pipeline")
      stage -> {:ok, stage}
    end
  end

  @doc "A text the body must carry, trimmed; `{:missing, [field]}` otherwise."
  @spec required_text(term(), atom()) :: {:ok, String.t()} | {:error, term()}
  def required_text(value, field) do
    case Leads.blank(value) do
      nil -> {:error, {:missing, [field]}}
      text -> {:ok, text}
    end
  end

  @doc "An optional day (`hold_until_on`)."
  @spec day(term()) :: {:ok, Date.t() | nil} | {:error, term()}
  def day(nil), do: {:ok, nil}
  def day(""), do: {:ok, nil}

  def day(value) do
    case Date.from_iso8601(to_string(value)) do
      {:ok, day} -> {:ok, day}
      _bad -> Leads.invalid("hold_until_on", "is a day")
    end
  end

  @doc "Where the lead stands, in words: \"In progress · Technical interview 1\"."
  @spec place(map()) :: String.t()
  def place(lead), do: Words.place(lead.state, lead.stage && lead.stage.name, lead.outcome)

  @doc "The 422 of a verb the lead's state does not allow."
  @spec cant(atom(), map()) :: {:error, term()}
  def cant(verb, lead) do
    words = String.replace(to_string(verb), "_", " ")
    Leads.invalid("state", "can't #{words} a lead that is #{Words.state(lead.state)}")
  end
end
