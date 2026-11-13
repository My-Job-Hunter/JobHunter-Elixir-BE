defmodule Core.Media do
  @moduledoc """
  The three-step upload (AQ-01 §4.1, mCart's): **reserve** a row
  (`POST /media`), **store** the bytes (`PUT /media/:id/blob`, sniffed against
  the allowlist and the declared type, capped per kind), **confirm**
  (`POST /media/:id/confirm`, marks `uploaded_at`). A file is read with a
  link signed for an hour (`GET /media/:id?t=`), never by path alone.

  Allowlist (QP1-3): JPEG, PNG, WebP for a photo; PDF, DOCX, text, markdown
  for a document; any of them for an attachment; AQ-06 §11.6 an email
  (`message/rfc822`) for an `eml`, read by `POST /eml`. 5 MB for a photo
  or an email, 10 MB otherwise. Unconfirmed rows older than a day are
  swept (`sweep_unconfirmed/1`). An email's attachments are stored with
  `store_attachment/4`, sniffed against the same allowlist.
  """

  alias Core.Storage
  alias Core.Storage.Content
  alias Data.Files
  alias Data.Files.Media
  alias Data.Scope

  @salt "media"
  @link_max_age 3_600

  @photo_types ~w(image/jpeg image/png image/webp)
  @document_types ~w(application/pdf
                     application/vnd.openxmlformats-officedocument.wordprocessingml.document
                     text/plain text/markdown)

  @doc "The content types each kind may declare."
  @spec allowed_types(atom()) :: [String.t()]
  def allowed_types(:photo), do: @photo_types
  def allowed_types(:document), do: @document_types
  def allowed_types(:attachment), do: @photo_types ++ @document_types
  def allowed_types(:eml), do: ["message/rfc822"]

  @doc "Step 1: reserves the row and says where to send the bytes. `path` is the caller's `/media` route."
  @spec create(Scope.t(), map(), String.t()) ::
          {:ok, Media.t(), Storage.upload_target()} | {:error, term()}
  def create(%Scope{} = scope, params, path) do
    with {:ok, kind} <- kind(params["media_kind"]),
         {:ok, type} <- allowed(kind, params["content_type"]),
         {:ok, bytes} <- declared_size(params["byte_count"], kind),
         {:ok, media} <-
           Files.create(%{
             organisation_id: Scope.organisation_id(scope),
             owner_user_id: Scope.user_id(scope),
             media_kind: kind,
             storage_key: Storage.key_for(type),
             content_type: type,
             byte_count: bytes,
             original_filename: blank(params["original_filename"])
           }),
         {:ok, target} <- Storage.upload_target(media.storage_key, media.id, path) do
      {:ok, media, target}
    end
  end

  @doc "Step 2: the bytes, checked against the cap, the allowlist and the declared type, then stored."
  @spec store(Scope.t(), binary(), binary()) :: :ok | {:error, term()}
  def store(%Scope{} = scope, id, body) when is_binary(body) do
    with %Media{uploaded_at: nil} = media <-
           Files.get_own(Scope.user_id(scope), id) || {:error, :not_found},
         :ok <- within(byte_size(body), media.media_kind),
         true <- Content.matches?(body, media.content_type) || {:error, :file_mismatch},
         :ok <- Storage.put(media.storage_key, body),
         {:ok, _stored} <-
           Files.mark_stored(media, %{
             sha256: :crypto.hash(:sha256, body),
             byte_count: byte_size(body)
           }) do
      :ok
    else
      %Media{} -> {:error, :not_found}
      other -> other
    end
  end

  @doc "Step 3: says the bytes arrived, with what the client knows about them (pixels, pages)."
  @spec confirm(Scope.t(), binary(), map(), DateTime.t()) :: {:ok, Media.t()} | {:error, term()}
  def confirm(%Scope{} = scope, id, params, %DateTime{} = now) do
    with %Media{} = media <- Files.get_own(Scope.user_id(scope), id) || {:error, :not_found},
         :ok <- arrived(media) do
      Files.mark_uploaded(
        media,
        %{
          width_px: whole(params["width_px"]),
          height_px: whole(params["height_px"]),
          page_count: whole(params["page_count"])
        },
        now
      )
    end
  end

  @doc "A confirmed file's bytes, for whoever carries a link signed within the hour."
  @spec read(binary(), String.t() | nil) :: {:ok, Media.t(), binary()} | {:error, :not_found}
  def read(id, token) do
    with %Media{uploaded_at: %DateTime{}} = media <- Files.get(id) || {:error, :not_found},
         true <- signed?(media.id, token),
         {:ok, bytes} <- Storage.fetch(media.storage_key) do
      {:ok, media, bytes}
    else
      _missing_unsigned_or_unreadable -> {:error, :not_found}
    end
  end

  @doc "A confirmed file of `kind` the caller uploaded, or `:not_found`."
  @spec own_uploaded(Scope.t(), binary(), atom()) :: {:ok, Media.t()} | {:error, :not_found}
  def own_uploaded(%Scope{} = scope, id, kind) do
    case Files.get_own(Scope.user_id(scope), id) do
      %Media{uploaded_at: %DateTime{}, media_kind: ^kind} = media -> {:ok, media}
      _other -> {:error, :not_found}
    end
  end

  @doc """
  An email's attachment kept (AQ-06 §7.1): its bytes sniffed (never the
  part's declared type), on the attachment allowlist and under its cap,
  stored and confirmed at once as the caller's `attachment`. Answers the
  row, or why it was not kept.
  """
  @spec store_attachment(Scope.t(), binary(), String.t() | nil, DateTime.t()) ::
          {:ok, Media.t()} | {:error, term()}
  def store_attachment(%Scope{} = scope, bytes, filename, %DateTime{} = now)
      when is_binary(bytes) do
    type = Content.detect(bytes)

    with true <- (type && type in allowed_types(:attachment)) || {:error, :file_type_not_allowed},
         :ok <- within(byte_size(bytes), :attachment),
         key = Storage.key_for(type),
         :ok <- Storage.put(key, bytes),
         {:ok, media} <-
           Files.create(%{
             organisation_id: Scope.organisation_id(scope),
             owner_user_id: Scope.user_id(scope),
             media_kind: :attachment,
             storage_key: key,
             content_type: type,
             byte_count: byte_size(bytes),
             original_filename: blank(filename)
           }),
         {:ok, media} <-
           Files.mark_stored(media, %{
             sha256: :crypto.hash(:sha256, bytes),
             byte_count: byte_size(bytes)
           }) do
      Files.mark_uploaded(media, %{}, now)
    end
  end

  @doc """
  A forwarded mail's raw bytes kept (AQ-09 QP9-20) as an `eml`
  (`message/rfc822`), stored and confirmed at once, the way an upload's
  `.eml` is kept: the message's `source_media_id`, re-read for an
  invitation when triage links it later, deleted with the message's
  conversation. Its size was capped by the webhook (30 MB), not here.
  """
  @spec store_email(Scope.t(), binary(), DateTime.t()) :: {:ok, Media.t()} | {:error, term()}
  def store_email(%Scope{} = scope, bytes, %DateTime{} = now)
      when is_binary(bytes) and byte_size(bytes) > 0 do
    key = Storage.key_for("message/rfc822")

    with :ok <- Storage.put(key, bytes),
         {:ok, media} <-
           Files.create(%{
             organisation_id: Scope.organisation_id(scope),
             owner_user_id: Scope.user_id(scope),
             media_kind: :eml,
             storage_key: key,
             content_type: "message/rfc822",
             byte_count: byte_size(bytes),
             original_filename: "forwarded.eml"
           }),
         {:ok, media} <-
           Files.mark_stored(media, %{
             sha256: :crypto.hash(:sha256, bytes),
             byte_count: byte_size(bytes)
           }) do
      Files.mark_uploaded(media, %{}, now)
    end
  end

  @doc "The link a view hands out: the file's path with a token good for an hour, relative to the API prefix."
  @spec link(binary()) :: String.t()
  def link(id), do: "/media/#{id}?t=#{Plug.Crypto.sign(secret(), @salt, id)}"

  @doc "What a screen is told about a file."
  @spec view(Media.t()) :: map()
  def view(%Media{} = m) do
    %{
      id: m.id,
      media_kind: m.media_kind,
      content_type: m.content_type,
      byte_count: m.byte_count,
      width_px: m.width_px,
      height_px: m.height_px,
      page_count: m.page_count,
      original_filename: m.original_filename,
      uploaded_at: m.uploaded_at,
      url: link(m.id)
    }
  end

  @doc "Removes rows reserved more than a day before `now` whose upload never completed, and their bytes."
  @spec sweep_unconfirmed(DateTime.t()) :: non_neg_integer()
  def sweep_unconfirmed(%DateTime{} = now) do
    now
    |> DateTime.add(-1, :day)
    |> Files.list_unconfirmed_for_system()
    |> Enum.map(fn media ->
      :ok = Storage.delete(media.storage_key)
      {:ok, _gone} = Files.delete_for_system(media)
    end)
    |> length()
  end

  # ── Checks ──────────────────────────────────────────────────────────────────

  defp kind(kind) when kind in ~w(photo document attachment eml),
    do: {:ok, String.to_existing_atom(kind)}

  defp kind(_other), do: {:error, {:missing, :media_kind}}

  defp allowed(kind, type) when is_binary(type) do
    if type in allowed_types(kind), do: {:ok, type}, else: {:error, :file_type_not_allowed}
  end

  defp allowed(_kind, _missing), do: {:error, {:missing, :content_type}}

  defp declared_size(bytes, kind) when is_integer(bytes) and bytes > 0 do
    with :ok <- within(bytes, kind), do: {:ok, bytes}
  end

  defp declared_size(bytes, kind) when is_binary(bytes) do
    case Integer.parse(bytes) do
      {n, ""} -> declared_size(n, kind)
      _other -> {:error, {:missing, :byte_count}}
    end
  end

  defp declared_size(_other, _kind), do: {:error, {:missing, :byte_count}}

  defp within(bytes, kind) do
    limit = Storage.max_bytes(kind)
    if bytes <= limit, do: :ok, else: {:error, {:file_too_large, limit}}
  end

  defp arrived(%Media{sha256: sha} = media) when is_binary(sha) do
    if Storage.size(media.storage_key), do: :ok, else: {:error, {:missing, :blob}}
  end

  defp arrived(_media), do: {:error, {:missing, :blob}}

  defp signed?(_id, nil), do: false

  defp signed?(id, token) do
    case Plug.Crypto.verify(secret(), @salt, token, max_age: @link_max_age) do
      {:ok, ^id} -> true
      _other -> false
    end
  end

  # Guardian's key signs the links too: one secret to rotate, and no
  # endpoint needed, so `core` signs on its own.
  defp secret, do: Application.fetch_env!(:core, Core.Auth.Guardian)[:secret_key]

  defp whole(n) when is_integer(n) and n >= 0, do: n

  defp whole(n) when is_binary(n) do
    case Integer.parse(n) do
      {i, ""} when i >= 0 -> i
      _other -> nil
    end
  end

  defp whole(_other), do: nil

  defp blank(nil), do: nil

  defp blank(s) when is_binary(s) do
    case String.trim(s) do
      "" -> nil
      trimmed -> String.slice(trimmed, 0, 200)
    end
  end
end
