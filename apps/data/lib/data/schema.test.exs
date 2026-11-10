defmodule Data.SchemaTest do
  @moduledoc """
  The one key style and the one time type, asserted on a schema that uses
  them — so the first real table cannot be the first place they are tried.
  """

  use ExUnit.Case, async: true

  defmodule Probe do
    @moduledoc false
    use Data.Schema

    schema "probes" do
      timestamps()
    end
  end

  test "keys are UUIDv7, made by the application" do
    assert Probe.__schema__(:primary_key) == [:id]
    assert {:parameterized, {Uniq.UUID, params}} = Probe.__schema__(:type, :id)

    id = Uniq.UUID.autogenerate(params)

    assert %Uniq.UUID{version: 7} = Uniq.UUID.info!(id)
  end

  test "timestamps are UTC with microseconds" do
    assert Probe.__schema__(:type, :inserted_at) == :utc_datetime_usec
    assert Probe.__schema__(:type, :updated_at) == :utc_datetime_usec
  end
end
