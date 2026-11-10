defmodule ApiShared.FallbackController do
  @moduledoc """
  The single error contract (copied from AutoCare). Written before the second
  controller exists, because an error shape that is converged on is an error
  shape that differs per endpoint.

  Controllers return `{:error, :not_found}` and this turns it into JSON. One
  place defines every status code and every controller stays readable.

  ## The shape

      {"error": {"code": "...", "message": "...", "details": {...}}}

  Per `docs/CONVENTIONS.md` §7. The **`code` is the contract**; the `message`
  is for humans and may be reworded at any time. A client matching on English
  prose breaks the first time someone improves the copy; the extension, which
  updates on the store's schedule rather than ours, matches on codes for
  longest.

  **A new code is a new clause here and a new row in CONVENTIONS §7**, in the
  same change. PLAN §15.5's codes (`duplicate_application`, `lead_moved`, …)
  are reserved there and arrive with the phases that raise them.

  ## Scoped 404, never 403

  A resource the caller may not know exists returns `:not_found`. A 403
  confirms the row is there, which is itself the leak.
  """

  use Phoenix.Controller, formats: [:json]

  require Logger

  alias Core.Accounts.Password
  alias Ecto.Changeset

  def call(conn, {:error, %Changeset{} = changeset}) do
    respond(conn, 422, "validation_failed", "Some fields need fixing.", errors_on(changeset))
  end

  # A required parameter that never arrived. Same status and code as a
  # changeset failure because it is the same problem from the client's side,
  # and `details` names the field.
  def call(conn, {:error, {:missing, fields}}) do
    details = Map.new(List.wrap(fields), &{to_string(&1), ["is required"]})

    respond(conn, 422, "validation_failed", "Some fields need fixing.", details)
  end

  # A body the context cannot act on as sent, with `details` naming the
  # fields: a profile PATCH mixing pitch and facts, a document with both a
  # file and a url. The same status and code as a changeset failure.
  def call(conn, {:error, {:invalid, details}}) when is_map(details) do
    respond(conn, 422, "validation_failed", "Some fields need fixing.", details)
  end

  def call(conn, {:error, :not_found}) do
    respond(conn, 404, "not_found", "We could not find that.")
  end

  def call(conn, {:error, :unauthenticated}) do
    respond(conn, 401, "unauthenticated", "You need to sign in to do that.")
  end

  # A guard refusal carries its own words, phrased for the person rather than
  # for a log.
  def call(conn, {:error, {:forbidden, reason}}) when is_binary(reason) do
    respond(conn, 403, "forbidden", reason)
  end

  def call(conn, {:error, :forbidden}) do
    respond(conn, 403, "forbidden", "You do not have permission to do that.")
  end

  def call(conn, {:error, :conflict}) do
    respond(conn, 409, "conflict", "Somebody else changed this first. Reload and try again.")
  end

  # ── Identity (JH-01 §6.5) ───────────────────────────────────────────────────

  # The same words for a wrong email and a wrong password.
  def call(conn, {:error, :invalid_credentials}) do
    respond(conn, 401, "invalid_credentials", "That email and password don't match.")
  end

  def call(conn, {:error, :account_not_found}) do
    respond(conn, 404, "account_not_found", "No account has that email. Ask for an invitation.")
  end

  def call(conn, {:error, :account_suspended}) do
    respond(conn, 403, "account_suspended", "This account is paused. Ask your manager.")
  end

  def call(conn, {:error, :invalid_refresh_token}) do
    respond(conn, 401, "invalid_refresh_token", "Your session has ended. Sign in again.")
  end

  def call(conn, {:error, :invitation_invalid}) do
    respond(conn, 404, "invitation_invalid", "That invitation does not exist or was withdrawn.")
  end

  # `details.expires_at` says when, so the screen can say "expired on 16 Nov".
  def call(conn, {:error, {:invitation_expired, %DateTime{} = at}}) do
    respond(conn, 410, "invitation_expired", "This invitation expired. Ask for a new one.", %{
      expires_at: DateTime.to_iso8601(at)
    })
  end

  def call(conn, {:error, :invitation_expired}) do
    respond(conn, 410, "invitation_expired", "This invitation expired. Ask for a new one.")
  end

  def call(conn, {:error, :invitation_used}) do
    respond(conn, 410, "invitation_used", "This invitation was already used. Sign in instead.")
  end

  def call(conn, {:error, :password_too_weak}) do
    respond(
      conn,
      422,
      "password_too_weak",
      "Choose at least #{Password.min_length()} characters, and not one of the most common passwords.",
      %{"password" => ["is too weak"]}
    )
  end

  def call(conn, {:error, :token_invalid}) do
    respond(conn, 410, "token_invalid", "That link is no longer valid. Ask for a new one.")
  end

  def call(conn, {:error, :email_taken}) do
    respond(conn, 409, "email_taken", "That email already has an account. Sign in instead.")
  end

  # ── The organisation (JH-01 §6.5) ───────────────────────────────────────────

  def call(conn, {:error, :last_admin}) do
    respond(conn, 409, "last_admin", "The organisation needs one admin. Grant another first.")
  end

  def call(conn, {:error, :role_above_yours}) do
    respond(conn, 403, "role_above_yours", "Only a manager can make a manager.")
  end

  def call(conn, {:error, :not_a_customer}) do
    respond(conn, 404, "not_a_customer", "This sign-in is for customers.")
  end

  # ── Files (JH-01 §6.5) ──────────────────────────────────────────────────────

  def call(conn, {:error, {:file_too_large, limit}}) when is_integer(limit) do
    respond(
      conn,
      413,
      "file_too_large",
      "That file is too big. The limit is #{megabytes(limit)}.",
      %{
        max_bytes: limit
      }
    )
  end

  def call(conn, {:error, :file_type_not_allowed}) do
    respond(
      conn,
      415,
      "file_type_not_allowed",
      "That kind of file cannot be uploaded. PDF, Word, text, markdown, JPEG, PNG or WebP."
    )
  end

  def call(conn, {:error, :file_mismatch}) do
    respond(conn, 422, "file_mismatch", "Those bytes are not the file that was declared.")
  end

  def call(conn, {:error, :rate_limited}) do
    respond(conn, 429, "rate_limited", "Too many attempts. Wait a moment and try again.")
  end

  # A throttle that knows when it lifts. Without this clause the tuple would
  # fall through to the backstop and answer a 500 for a rule working exactly
  # as intended. `retry_after_seconds` is spelled as `Core.Plugs.RateLimit`
  # spells it, so a client reads one name.
  def call(conn, {:error, {:rate_limited, seconds}}) when is_integer(seconds) do
    conn
    |> put_resp_header("retry-after", to_string(seconds))
    |> respond(
      429,
      "rate_limited",
      "That is a lot at once. Try again in #{minutes(seconds)}.",
      %{retry_after_seconds: seconds}
    )
  end

  # **The backstop.** An unmapped reason is a 500 that says nothing about
  # internals, and a log line naming the reason so the missing clause is found.
  def call(conn, {:error, reason}) do
    Logger.error("Unhandled error reached FallbackController: #{inspect(reason)}")

    respond(conn, 500, "internal_error", "Something went wrong at our end.")
  end

  # Said the way somebody would say it. "3600 seconds" is a unit nobody
  # thinks in, and "in 0 minutes" is worse than a rounding error.
  defp minutes(seconds) when seconds < 60, do: "a minute"
  defp minutes(seconds) when seconds < 120, do: "a minute or two"
  defp minutes(seconds), do: "#{div(seconds, 60)} minutes"

  defp megabytes(bytes) when bytes >= 1_000_000, do: "#{div(bytes, 1_000_000)} MB"
  defp megabytes(bytes), do: "#{div(bytes, 1000)} KB"

  defp respond(conn, status, code, message, details \\ %{}) do
    conn
    |> put_status(status)
    |> put_view(json: ApiShared.ErrorJSON)
    |> put_format("json")
    |> render(:error, code: code, message: message, details: details)
  end

  @doc """
  Changeset errors as `%{field => [message]}`.

  Interpolates the count/validation options into the message, so a client sees
  "should be at least 8 character(s)" rather than a template.
  """
  def errors_on(%Changeset{} = changeset) do
    Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _whole, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
