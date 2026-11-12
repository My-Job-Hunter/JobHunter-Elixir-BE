defmodule Core.Customers.Skills do
  @moduledoc """
  The skills vocabulary (AQ-01 §4.3, QP1-4): seeded (`Data.Seeds.Skills`),
  extended by staff, archived — never deleted — by a lead or above. Every
  signed-in account of the organisation reads it, the customer included,
  because the portal edits a profile's skills.
  """

  alias Core.Access
  alias Core.Audit
  alias Core.Customers
  alias Data.Customers.Skill
  alias Data.Scope
  alias Data.Skills, as: Store

  @fields ~w(name slug category archived_at)a

  @doc "`GET /skills?q`."
  @spec list(Scope.t(), map()) :: {:ok, [Skill.t()]} | {:error, term()}
  def list(%Scope{organisation: organisation} = scope, params \\ %{}) do
    params = Customers.stringify(params)

    with :ok <- Access.why_not(scope, :read, {:skill, %{}}),
         do: {:ok, Store.list(organisation.id, q: params["q"])}
  end

  @doc "`POST /skills {name, category, slug?}`."
  @spec create(Scope.t(), map(), DateTime.t()) :: {:ok, Skill.t()} | {:error, term()}
  def create(%Scope{organisation: organisation} = scope, params, %DateTime{} = now) do
    with :ok <- Access.why_not(scope, :create, {:skill, %{}}) do
      attrs =
        params
        |> Customers.stringify()
        |> Map.take(~w(name slug category))
        |> Map.put("organisation_id", organisation.id)

      Customers.commit(fn -> insert(scope, attrs, now) end)
    end
  end

  defp insert(scope, attrs, now) do
    with {:ok, skill} <- Store.create(attrs) do
      {:ok, _event} = Audit.record(scope, "created", skill, after: snapshot(skill), now: now)
      {:ok, skill}
    end
  end

  @doc "`POST /skills/:id/archive`: it leaves the pickers; profiles that name it keep it."
  @spec archive(Scope.t(), binary(), DateTime.t()) :: {:ok, Skill.t()} | {:error, term()}
  def archive(%Scope{organisation: organisation} = scope, id, %DateTime{} = now) do
    with %Skill{} = skill <- Store.get(organisation.id, id) || {:error, :not_found},
         :ok <- Access.why_not(scope, :archive, {:skill, skill}) do
      Customers.commit(fn ->
        {:ok, archived} = Store.archive(skill, now)

        {:ok, _event} =
          Audit.record(scope, "archived", archived,
            before: snapshot(skill),
            after: snapshot(archived),
            now: now
          )

        {:ok, archived}
      end)
    end
  end

  defp snapshot(skill), do: Audit.snapshot(skill, @fields)
end
