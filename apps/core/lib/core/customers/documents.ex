defmodule Core.Customers.Documents do
  @moduledoc """
  A profile's documents (AQ-01 §4.3, §6.2, §6.3). **A CV is one row per
  version**: `new_version/4` makes a row with `version_no + 1` that
  supersedes the given one, and moves the profile's default along when the
  superseded row held it, so a lead that was sent v4 keeps pointing at v4.

  A document has a file **or** a `url`. The file is a `media` row the
  caller uploaded and confirmed (the three-step upload), linked through
  `document_media`. Every staff role of a serving team, and the customer,
  has full run of documents (§5.3).
  """

  alias Core.Access
  alias Core.Audit
  alias Core.Customers
  alias Core.Customers.Profiles
  alias Core.Media
  alias Data.Customers.Document
  alias Data.Customers.Profile
  alias Data.Documents, as: Store
  alias Data.Profiles, as: ProfileStore
  alias Data.Scope

  @fields ~w(profile_id kind label version_no supersedes_document_id url archived_at)a

  @doc "`GET /profiles/:id/documents`."
  @spec list(Scope.t(), binary()) :: {:ok, [Document.t()]} | {:error, term()}
  def list(%Scope{} = scope, profile_id) do
    with {:ok, profile} <- Profiles.fetch(scope, :read, profile_id),
         :ok <- Access.why_not(scope, :read, {:document, %{profile: profile}}),
         do: {:ok, Store.list(profile.id)}
  end

  @doc "`GET /documents/:id`."
  @spec get(Scope.t(), binary()) :: {:ok, Document.t()} | {:error, term()}
  def get(%Scope{} = scope, id), do: fetch(scope, :read, id)

  defp fetch(%Scope{organisation: organisation} = scope, action, id) do
    with %Document{} = document <- Store.get(id) || {:error, :not_found},
         true <-
           document.profile.customer.organisation_id == organisation.id || {:error, :not_found},
         :ok <- Access.why_not(scope, action, {:document, document}) do
      {:ok, document}
    end
  end

  @doc "`POST /profiles/:id/documents {kind, label, media_id? | url?}`: exactly one of the two."
  @spec create(Scope.t(), binary(), map(), DateTime.t()) ::
          {:ok, Document.t()} | {:error, term()}
  def create(%Scope{} = scope, profile_id, params, %DateTime{} = now) do
    params = Customers.stringify(params)

    with {:ok, profile} <- Profiles.fetch(scope, :read, profile_id),
         :ok <- Access.why_not(scope, :create, {:document, %{profile: profile}}),
         {:ok, source} <- source(scope, params) do
      attrs = params |> Map.take(~w(kind label)) |> Map.put("profile_id", profile.id)
      Customers.commit(fn -> insert(scope, attrs, source, now) end)
    end
  end

  @doc """
  `POST /documents/:id/new-version {media_id? | url?}`: the next version
  of the same label, superseding this one; the default follows.
  """
  @spec new_version(Scope.t(), binary(), map(), DateTime.t()) ::
          {:ok, Document.t()} | {:error, term()}
  def new_version(%Scope{} = scope, id, params, %DateTime{} = now) do
    params = Customers.stringify(params)

    with {:ok, old} <- fetch(scope, :create, id),
         {:ok, source} <- source(scope, params) do
      attrs = %{
        "profile_id" => old.profile_id,
        "kind" => old.kind,
        "label" => old.label,
        "version_no" => Store.last_version(old.profile_id, old.label) + 1,
        "supersedes_document_id" => old.id
      }

      Customers.commit(fn -> insert_version(scope, old, attrs, source, now) end)
    end
  end

  defp insert_version(scope, old, attrs, source, now) do
    with {:ok, document} <- insert(scope, attrs, source, now),
         :ok <- follow_default(old, document) do
      {:ok, Store.reload(document)}
    end
  end

  # The superseded row held the default: the new version takes it.
  defp follow_default(%Document{profile: profile, id: id} = old, document) do
    if Profile.default_document_id(profile) == id do
      with {:ok, _link} <- ProfileStore.put_default_document(old.profile, document.id), do: :ok
    else
      :ok
    end
  end

  # One of: `{:media, media}` (uploaded and confirmed by the caller) or `{:url, url}`.
  defp source(scope, %{"media_id" => media_id} = params)
       when is_binary(media_id) and media_id != "" do
    if blank?(params["url"]) do
      with {:ok, media} <- Media.own_uploaded(scope, media_id, :document),
           do: {:ok, {:media, media}}
    else
      {:error, {:invalid, %{"url" => ["cannot be given with media_id"]}}}
    end
  end

  defp source(_scope, %{"url" => url}) when is_binary(url) and url != "", do: {:ok, {:url, url}}
  defp source(_scope, _neither), do: {:error, {:missing, :media_id}}

  defp insert(scope, attrs, source, now) do
    attrs =
      case source do
        {:url, url} -> Map.put(attrs, "url", url)
        {:media, _media} -> Map.delete(attrs, "url")
      end

    with {:ok, document} <- Store.create(attrs),
         {:ok, _link} <- attach(document, source) do
      {:ok, _event} =
        Audit.record(scope, "created", document, after: snapshot(document), now: now)

      {:ok, Store.reload(document)}
    end
  end

  defp attach(document, {:media, media}), do: Store.attach_media(document, media.id)
  defp attach(_document, {:url, _url}), do: {:ok, nil}

  @doc "`PATCH /documents/:id {label?, kind?, url?}`: a url only on a document that has one."
  @spec update(Scope.t(), binary(), map()) :: {:ok, Document.t()} | {:error, term()}
  def update(%Scope{} = scope, id, params) do
    params = Customers.stringify(params)

    with {:ok, document} <- fetch(scope, :update, id),
         {:ok, attrs} <- updatable(document, params) do
      Customers.commit(fn -> write(scope, document, attrs) end)
    end
  end

  defp write(scope, document, attrs) do
    with {:ok, updated} <- Store.update(document, attrs) do
      {:ok, _event} =
        Audit.record(scope, "updated", updated,
          before: snapshot(document),
          after: snapshot(updated)
        )

      {:ok, Store.reload(updated)}
    end
  end

  defp updatable(document, params) do
    attrs = Map.take(params, ~w(label kind url))

    if Map.has_key?(attrs, "url") and not is_nil(Document.media(document)),
      do: {:error, {:invalid, %{"url" => ["this document is a file, not a link"]}}},
      else: {:ok, attrs}
  end

  @doc "`POST /documents/:id/archive`."
  @spec archive(Scope.t(), binary(), DateTime.t()) :: {:ok, Document.t()} | {:error, term()}
  def archive(%Scope{} = scope, id, %DateTime{} = now) do
    with {:ok, document} <- fetch(scope, :archive, id) do
      Customers.commit(fn ->
        {:ok, archived} = Store.archive(document, now)

        {:ok, _event} =
          Audit.record(scope, "archived", archived,
            before: snapshot(document),
            after: snapshot(archived),
            now: now
          )

        {:ok, Store.reload(archived)}
      end)
    end
  end

  @doc "`PUT /profiles/:id/default-document {document_id}`: one of the profile's own live documents."
  @spec put_default(Scope.t(), binary(), binary()) :: {:ok, Profile.t()} | {:error, term()}
  def put_default(%Scope{} = scope, profile_id, document_id) do
    with {:ok, profile} <- Profiles.fetch(scope, :read, profile_id),
         :ok <- Access.why_not(scope, :update, {:document, %{profile: profile}}),
         %Document{archived_at: nil} = document <- own_document(profile, document_id) do
      Customers.commit(fn ->
        {:ok, _link} = ProfileStore.put_default_document(profile, document.id)

        {:ok, _event} =
          Audit.record(scope, "default_document_set", profile,
            before: %{"document_id" => Profile.default_document_id(profile)},
            after: %{"document_id" => document.id}
          )

        {:ok, ProfileStore.reload(profile)}
      end)
    end
  end

  defp own_document(profile, document_id) do
    case Store.get(document_id) do
      %Document{profile_id: id} = document when id == profile.id -> document
      _other -> {:error, :not_found}
    end
  end

  defp blank?(nil), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: false
  defp snapshot(document), do: Audit.snapshot(document, @fields)
end
