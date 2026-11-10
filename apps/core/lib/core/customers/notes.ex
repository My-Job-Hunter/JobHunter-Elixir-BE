defmodule Core.Customers.Notes do
  @moduledoc """
  Staff-only notes about a customer (JH-01 §4.3, §6.2). Never in the
  portal: a customer's scope answers `:not_found` for them, and no portal
  route exists. Anyone who sees the customer reads them; a lead or above
  writes; the author edits or deletes their own, a lead or above anyone's.
  """

  alias Core.Access
  alias Core.Audit
  alias Core.Customers
  alias Data.Customers, as: Store
  alias Data.Customers.CustomerNote
  alias Data.Scope

  @fields ~w(customer_id author_user_id body_md edited_at deleted_at)a

  @doc "`GET /customers/:id/notes`."
  @spec list(Scope.t(), binary()) :: {:ok, [CustomerNote.t()]} | {:error, term()}
  def list(%Scope{} = scope, customer_id) do
    with {:ok, customer} <- Customers.fetch(scope, :read_notes, customer_id),
         do: {:ok, Store.list_notes(customer.id)}
  end

  @doc "`POST /customers/:id/notes {body_md}`."
  @spec create(Scope.t(), binary(), map(), DateTime.t()) ::
          {:ok, CustomerNote.t()} | {:error, term()}
  def create(%Scope{} = scope, customer_id, params, %DateTime{} = now) do
    with {:ok, customer} <- Customers.fetch(scope, :write_note, customer_id) do
      attrs = %{
        customer_id: customer.id,
        author_user_id: Scope.user_id(scope),
        body_md: Customers.stringify(params)["body_md"]
      }

      Customers.commit(fn -> insert(scope, attrs, now) end)
    end
  end

  defp insert(scope, attrs, now) do
    with {:ok, note} <- Store.create_note(attrs) do
      {:ok, _event} = Audit.record(scope, "created", note, after: snapshot(note), now: now)
      {:ok, note}
    end
  end

  @doc "`PATCH /notes/:id {body_md}`: by its author, or a lead or above."
  @spec update(Scope.t(), binary(), map(), DateTime.t()) ::
          {:ok, CustomerNote.t()} | {:error, term()}
  def update(%Scope{} = scope, id, params, %DateTime{} = now) do
    with {:ok, note} <- fetch(scope, id) do
      Customers.commit(fn -> write(scope, note, params, now) end)
    end
  end

  defp write(scope, note, params, now) do
    with {:ok, updated} <- Store.update_note(note, params, now) do
      {:ok, _event} =
        Audit.record(scope, "updated", updated,
          before: snapshot(note),
          after: snapshot(updated),
          now: now
        )

      {:ok, %{updated | author_user: note.author_user}}
    end
  end

  @doc "`DELETE /notes/:id`: the row stays, marked deleted."
  @spec delete(Scope.t(), binary(), DateTime.t()) :: :ok | {:error, term()}
  def delete(%Scope{} = scope, id, %DateTime{} = now) do
    with {:ok, note} <- fetch(scope, id),
         {:ok, :ok} <-
           Customers.commit(fn ->
             {:ok, deleted} = Store.delete_note(note, now)

             {:ok, _event} =
               Audit.record(scope, "deleted", deleted, before: snapshot(note), now: now)

             {:ok, :ok}
           end) do
      :ok
    end
  end

  # A note the caller may change: visible through the customer, and either
  # theirs or within a lead's reach. A member's reach over another's note is
  # the customer's `:write_note` refusal, in words.
  defp fetch(%Scope{organisation: organisation} = scope, id) do
    with %CustomerNote{} = note <- Store.get_note(id) || {:error, :not_found},
         true <- note.customer.organisation_id == organisation.id || {:error, :not_found},
         :ok <- Access.why_not(scope, :read_notes, {:customer, note.customer}),
         :ok <- may_change(scope, note) do
      {:ok, note}
    end
  end

  defp may_change(scope, note) do
    if note.author_user_id == Scope.user_id(scope),
      do: :ok,
      else: Access.why_not(scope, :write_note, {:customer, note.customer})
  end

  defp snapshot(note), do: Audit.snapshot(note, @fields)
end
