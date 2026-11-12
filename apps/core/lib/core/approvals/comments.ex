defmodule Core.Approvals.Comments do
  @moduledoc """
  An approval's comments (AQ-07 §5.2, QP7-9): **one stream**, read and
  written by everyone who sees the approval — the customer too when they
  hold a slot; no staff-only comment in P7. The requester and the
  reviewers are told (`approvals.commented`), never the author. A comment
  is deleted by its author or a team lead, and keeps its place with no
  body.
  """

  alias Core.Access
  alias Core.Approvals
  alias Core.Approvals.{Notices, Sheet}
  alias Core.Audit
  alias Core.Leads
  alias Core.Realtime
  alias Core.Tasks.Write
  alias Data.Approvals, as: Store
  alias Data.Scope

  @doc "`GET /approvals/:id/comments`: the stream, oldest first, as **comments**."
  @spec list(Scope.t(), term()) :: {:ok, [map()]} | {:error, term()}
  def list(%Scope{} = scope, id) do
    with {:ok, a} <- Approvals.fetch(scope, :read, id),
         do: {:ok, Enum.map(Store.comments(a.id), &Sheet.comment(scope, a, &1))}
  end

  @doc "`POST /approvals/:id/comments {body_md}`: answers the **comment**."
  @spec create(Scope.t(), term(), map(), DateTime.t()) :: {:ok, map()} | {:error, term()}
  def create(%Scope{} = scope, id, params, %DateTime{} = now) do
    body = Leads.stringify(params)["body_md"]

    with {:ok, a} <- Approvals.fetch(scope, :comment, id),
         {:ok, body} <- body(body),
         {:ok, c} <- Write.commit(fn -> posted(scope, a, body, now) end),
         do: {:ok, Sheet.comment(scope, a, c)}
  end

  defp posted(scope, a, body, now) do
    attrs = %{approval_id: a.id, author_user_id: Scope.user_id(scope), body_md: body}

    with {:ok, c} <- Store.add_comment(attrs) do
      {:ok, _audit} =
        Audit.record(scope, "commented", c, after: %{"approval_id" => a.id}, now: now)

      {:ok, c, [Notices.commented(scope, a, c), Realtime.approval_changed(a)]}
    end
  end

  @doc "`DELETE /approval-comments/:id`: its author's or a team lead's; a tombstone. Answers `:ok`."
  @spec delete(Scope.t(), term(), DateTime.t()) :: :ok | {:error, term()}
  def delete(%Scope{} = scope, id, %DateTime{} = now) do
    with %{deleted_at: nil} = c <- Store.get_comment(id) || {:error, :not_found},
         %{} = a <- Store.get(Scope.organisation_id(scope), c.approval_id) || {:error, :not_found},
         :ok <-
           Access.why_not(
             scope,
             :delete,
             {:approval_comment, %{author_user_id: c.author_user_id, approval: Sheet.subject(a)}}
           ),
         {:ok, _gone} <- Write.commit(fn -> deleted(scope, a, c, now) end) do
      :ok
    else
      %{deleted_at: %DateTime{}} -> {:error, :not_found}
      error -> error
    end
  end

  defp deleted(scope, a, c, now) do
    with {:ok, gone} <- Store.delete_comment(c, now) do
      {:ok, _audit} =
        Audit.record(scope, "deleted", gone, before: %{"approval_id" => a.id}, now: now)

      {:ok, gone, Realtime.approval_changed(a)}
    end
  end

  defp body(value) do
    case Leads.blank(value) do
      nil ->
        {:error, {:missing, [:body_md]}}

      text ->
        if String.length(text) > 5000,
          do: Leads.invalid("body_md", "is too long (5,000 at most)"),
          else: {:ok, String.trim(text)}
    end
  end
end
