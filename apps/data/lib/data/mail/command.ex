defmodule Data.Mail.Command do
  @moduledoc """
  What one enqueued message says, checked before it is enqueued (mCart's
  seam, CONVENTIONS §7).

  **Why it lives in `data`**: `core` decides to send and `notifire` sends,
  and neither may name the other. `data` is the floor both stand on, so a
  struct here is the one place both ends agree on a shape — the same reason
  `Data.Scope` lives here.

  **The secret** is for a value that must not be stored anywhere durable: a
  reset token, whose row holds only a digest. It rides in the job's args,
  bounded by the token's own expiry. Never put one in `options`, which is for
  things worth logging.
  """

  @enforce_keys [:kind, :subject_id]
  defstruct [:kind, :subject_id, :secret, options: %{}]

  @type t :: %__MODULE__{
          kind: atom(),
          subject_id: String.t(),
          secret: String.t() | nil,
          options: map()
        }

  @doc "Builds a command, or says which fields are missing."
  @spec new(map()) :: {:ok, t()} | {:error, String.t()}
  def new(params) when is_map(params) do
    kind = params |> get(:kind) |> to_kind()
    subject_id = get(params, :subject_id)

    missing =
      [{:kind, kind}, {:subject_id, subject_id}]
      |> Enum.filter(fn {_key, value} -> is_nil(value) end)
      |> Enum.map(&elem(&1, 0))

    case missing do
      [] ->
        {:ok,
         %__MODULE__{
           kind: kind,
           subject_id: subject_id,
           secret: get(params, :secret),
           options: get(params, :options) || %{}
         }}

      missing ->
        {:error, "Missing required fields: #{inspect(missing)}"}
    end
  end

  def new(_params), do: {:error, "Params must be a map"}

  @doc "The same, raising — for a call site that has no way to recover."
  @spec new!(map()) :: t()
  def new!(params) do
    case new(params) do
      {:ok, command} -> command
      {:error, reason} -> raise ArgumentError, reason
    end
  end

  @doc "The map that goes into `Oban.Job.new/2`."
  @spec to_job_args(t()) :: map()
  def to_job_args(%__MODULE__{} = command) do
    %{
      "kind" => Atom.to_string(command.kind),
      "subject_id" => command.subject_id,
      "secret" => command.secret,
      "options" => stringify_keys(command.options)
    }
  end

  @doc """
  The command back out of a job. `String.to_existing_atom/1`, so a job row
  naming a kind this build has never heard of is refused rather than growing
  the atom table from user data.
  """
  @spec from_job_args(map()) :: {:ok, t()} | {:error, String.t()}
  def from_job_args(args) when is_map(args) do
    new(%{
      kind: args["kind"],
      subject_id: args["subject_id"],
      secret: args["secret"],
      options: args["options"] || %{}
    })
  end

  def from_job_args(_args), do: {:error, "Args must be a map"}

  defp get(map, key), do: Map.get(map, key) || Map.get(map, to_string(key))

  defp to_kind(nil), do: nil
  defp to_kind(kind) when is_atom(kind), do: kind

  defp to_kind(kind) when is_binary(kind) do
    String.to_existing_atom(kind)
  rescue
    ArgumentError -> nil
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {key, value}
    end)
  end

  defp stringify_keys(value), do: value
end
