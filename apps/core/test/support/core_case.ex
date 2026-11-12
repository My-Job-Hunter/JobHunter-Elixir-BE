defmodule Core.CoreCase do
  @moduledoc """
  For orchestration tests, which do touch the database.

  The pure engines need none of this — a rule that takes `now` and data and
  returns a decision runs without a sandbox, which is the point of keeping it
  pure.
  """

  use ExUnit.CaseTemplate

  alias Ecto.Adapters.SQL.Sandbox

  using do
    quote do
      import Core.CoreCase
      import Data.Fixtures

      alias Data.Repo
    end
  end

  setup tags do
    pid = Sandbox.start_owner!(Data.Repo, shared: not tags[:async])
    on_exit(fn -> Sandbox.stop_owner(pid) end)
    :ok
  end

  @doc """
  An `.eml` uploaded and confirmed by `scope`'s person (AQ-06 §11.6), from
  `apps/core/priv/eml/<name>` or the bytes given: the `eml` media row.
  """
  def eml_media(scope, name_or_bytes) do
    bytes =
      if String.ends_with?(name_or_bytes, ".eml"),
        do: File.read!(Path.expand("../../priv/eml/" <> name_or_bytes, __DIR__)),
        else: name_or_bytes

    {:ok, media, _target} =
      Core.Media.create(
        scope,
        %{
          "media_kind" => "eml",
          "content_type" => "message/rfc822",
          "byte_count" => byte_size(bytes),
          "original_filename" => "upload.eml"
        },
        "/media"
      )

    :ok = Core.Media.store(scope, media.id, bytes)
    {:ok, media} = Core.Media.confirm(scope, media.id, %{}, DateTime.utc_now())
    media
  end

  @doc "Changeset errors as %{field => [message]}, for readable assertions."
  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _whole, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
