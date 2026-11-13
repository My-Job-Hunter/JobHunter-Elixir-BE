defmodule ApiShared.FallbackController do
  @moduledoc """
  The single error contract (copied from mCart). Written before the second
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
  alias Core.Approvals.Sheet, as: ApprovalSheet
  alias Core.Leads.Words, as: LeadWords
  alias Core.Tasks.Words
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

  # ── The board (AQ-02 §7.5) ──────────────────────────────────────────────────

  # Every move carries the state the client saw; the task is somewhere
  # else now, and `details` says where, so the screen can put it there.
  def call(conn, {:error, {:task_moved, %{state: state} = task}}) do
    stage =
      case Map.get(task, :stage) do
        %{id: id, name: name} -> %{id: id, name: name}
        _none -> nil
      end

    respond(
      conn,
      409,
      "task_moved",
      "This task moved while you were looking. It's now #{Words.state(state)}.",
      %{state: to_string(state), stage: stage}
    )
  end

  # ── The job pool (AQ-03 §7) ─────────────────────────────────────────────────

  # The link is a job already (or was merged into one): `details` names it,
  # so the form can offer *Open it*.
  def call(conn, {:error, {:job_exists, %{id: id, title: title}}}) do
    respond(conn, 409, "job_exists", "That link is already in the pool: #{title}.", %{
      job_id: id,
      title: title
    })
  end

  # The same link, held by a teammate the caller may not see (AQ-03B §5.1).
  def call(conn, {:error, {:job_exists, :hidden}}) do
    respond(
      conn,
      409,
      "job_exists",
      "That link is already in this team's pool, added by another member.",
      %{job_id: nil, title: nil}
    )
  end

  # A close or reopen whose `from` is not the job's status now.
  def call(conn, {:error, {:job_moved, %{status: status}}}) do
    respond(
      conn,
      409,
      "job_moved",
      "This job changed while you were looking. It's now #{status}.",
      %{status: to_string(status)}
    )
  end

  # ── Leads (AQ-04A §8.4, §11.3) ──────────────────────────────────────────────

  # The profile has a lead on this posting already (§6): `details.existing`
  # names it as far as the caller may know it, and the words were made by
  # the guard, which knows the visibility.
  def call(conn, {:error, {:duplicate_application, %{existing: existing, message: message}}}) do
    respond(conn, 409, "duplicate_application", message, %{existing: existing})
  end

  # A lead verb whose `from` is not where the lead is now.
  def call(conn, {:error, {:lead_moved, %{state: state} = lead}}) do
    stage =
      case Map.get(lead, :stage) do
        %{key: key, name: name} -> %{key: key, name: name}
        _none -> nil
      end

    respond(
      conn,
      409,
      "lead_moved",
      "This lead moved while you were looking. It's now " <>
        LeadWords.place(state, stage && stage.name, Map.get(lead, :outcome)) <> ".",
      %{state: to_string(state), stage: stage}
    )
  end

  def call(conn, {:error, :override_reason_required}) do
    respond(conn, 422, "override_reason_required", "Say why you're applying again.", %{
      "reason" => ["is required"]
    })
  end

  def call(conn, {:error, :outcome_required}) do
    respond(conn, 422, "outcome_required", "Say how it ended.", %{"outcome" => ["is required"]})
  end

  # ── The extension (AQ-05 §8, §11.3, QP5-9) ──────────────────────────────────

  # *I applied* from an account that is another customer's channel: the
  # application would be recorded on the wrong profile. `details.channel`
  # names it as far as the caller may know it (`null` for a channel of a
  # customer they don't serve).
  def call(conn, {:error, {:identity_mismatch, %{kind: kind, acting: acting} = mismatch}}) do
    site = LeadWords.value(kind)
    acting = acting.display_name

    {message, channel} =
      case mismatch.channel do
        %{id: id, customer: %{id: customer_id, display_name: name}} ->
          {"You're signed in as #{name}'s #{site}, not #{acting}'s. " <>
             "Switch the acting profile, then press again.",
           %{id: id, customer: %{id: customer_id, display_name: name}}}

        _unseen ->
          {"You're signed in to another customer's #{site}, not #{acting}'s. " <>
             "Switch the acting profile, then press again.", nil}
      end

    respond(conn, 409, "identity_mismatch", message, %{channel: channel})
  end

  # ── Contacts (AQ-06 §6, §11.6) ──────────────────────────────────────────────

  # A handle another contact holds: "That LinkedIn is Mei Chen's already.";
  # `details` names the contact, so the form can offer *Use Mei Chen*.
  def call(conn, {:error, {:contact_exists, %{contact_id: id, name: name} = exists}}) do
    respond(conn, 409, "contact_exists", contact_words(Map.get(exists, :kind), name), %{
      contact_id: id,
      name: name
    })
  end

  # ── Approvals (AQ-07 §4, §11.4) ─────────────────────────────────────────────

  # A decision on a version that has moved on, an approval no longer
  # pending, or a slot that has decided already: `details` says where it
  # is now, so the sheet can re-read and say so.
  def call(conn, {:error, {:approval_not_pending, %{state: state, version: version}}}) do
    respond(conn, 409, "approval_not_pending", approval_words(state), %{
      state: to_string(state),
      version: version
    })
  end

  def call(conn, {:error, :not_reviewer}) do
    respond(conn, 403, "not_reviewer", "This isn't yours to decide.")
  end

  # ── Forwarded mail and invitations (AQ-09 §4, §11.4) ────────────────────────

  # A confirm or dismiss on a meeting with nothing waiting for a person.
  def call(conn, {:error, {:meeting_not_proposed, %{status: status}}}) do
    respond(
      conn,
      409,
      "meeting_not_proposed",
      "This meeting isn't waiting for a confirmation.",
      %{
        status: to_string(status)
      }
    )
  end

  # The webhook's wrong basic-auth pair: 401 with no body (AQ-09 §4).
  def call(conn, {:error, :inbound_unauthorised}) do
    conn
    |> put_resp_header("www-authenticate", ~s(Basic realm="inbound"))
    |> send_resp(401, "")
  end

  # The webhook with no password configured on this server.
  def call(conn, {:error, :inbound_off}) do
    respond(conn, 503, "inbound_off", "Forwarded mail isn't set up on this server.")
  end

  def call(conn, {:error, :conflict}) do
    respond(conn, 409, "conflict", "Somebody else changed this first. Reload and try again.")
  end

  # ── Identity (AQ-01 §6.5) ───────────────────────────────────────────────────

  # The same words for a wrong email and a wrong password.
  def call(conn, {:error, :invalid_credentials}) do
    respond(conn, 401, "invalid_credentials", "That email and password don't match.")
  end

  def call(conn, {:error, :account_not_found}) do
    respond(conn, 404, "account_not_found", "No account has that email. Ask for an invitation.")
  end

  def call(conn, {:error, :account_suspended}) do
    respond(conn, 403, "account_suspended", "This account is paused. Ask your team lead.")
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

  def call(conn, {:error, :not_a_customer}) do
    respond(conn, 404, "not_a_customer", "This sign-in is for customers.")
  end

  # ── Files (AQ-01 §6.5) ──────────────────────────────────────────────────────

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

  @doc """
  A refusal as `{code, message}` without a response: what `POST /leads/bulk`
  lists for each lead it could not act on (AQ-04B §8.1, QP4b-19). The same
  codes and words as the clauses above, for the reasons a lead verb gives.
  """
  @spec describe(term()) :: %{code: String.t(), message: String.t()}
  def describe(%Changeset{} = changeset), do: field_words(errors_on(changeset))

  def describe({:missing, fields}),
    do: field_words(Map.new(List.wrap(fields), &{&1, ["is required"]}))

  def describe({:invalid, details}) when is_map(details), do: field_words(details)
  def describe(:not_found), do: %{code: "not_found", message: "We could not find that."}

  def describe({:forbidden, words}) when is_binary(words),
    do: %{code: "forbidden", message: words}

  def describe({:lead_moved, %{state: state} = lead}) do
    stage = Map.get(lead, :stage)

    %{
      code: "lead_moved",
      message:
        "This lead moved while you were looking. It's now " <>
          LeadWords.place(state, stage && Map.get(stage, :name), Map.get(lead, :outcome)) <> "."
    }
  end

  def describe({:duplicate_application, %{message: message}}),
    do: %{code: "duplicate_application", message: message}

  def describe(:outcome_required), do: %{code: "outcome_required", message: "Say how it ended."}

  def describe({:approval_not_pending, %{state: state}}),
    do: %{code: "approval_not_pending", message: approval_words(state)}

  def describe(:not_reviewer), do: %{code: "not_reviewer", message: "This isn't yours to decide."}

  def describe(:override_reason_required),
    do: %{code: "override_reason_required", message: "Say why you're applying again."}

  def describe(reason) do
    Logger.error("Unhandled bulk refusal: #{inspect(reason)}")
    %{code: "internal_error", message: "Something went wrong at our end."}
  end

  defp approval_words(state),
    do:
      "This approval changed while you were looking. It's now #{ApprovalSheet.state_words(state)}."

  defp contact_words(kind, name) do
    handle =
      case kind do
        :email -> "email"
        :linkedin -> "LinkedIn"
        :upwork -> "Upwork account"
        :phone -> "phone number"
        _other -> "handle"
      end

    "That #{handle} is #{name}'s already."
  end

  defp field_words(details) do
    message =
      Enum.map_join(details, " ", fn {field, messages} ->
        "#{String.capitalize(String.replace(to_string(field), "_", " "))} #{Enum.join(List.wrap(messages), ", ")}."
      end)

    %{code: "validation_failed", message: message}
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
