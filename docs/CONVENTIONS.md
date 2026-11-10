# Job Hunter Backend — Conventions

The enforced rules for this codebase, adapted from AutoCare's. `CLAUDE.md` is
the index; `AGENTS.md` covers Phoenix mechanics; `../PLAN.md` is the product.
This covers Job Hunter's own decisions.

---

## 1. Layering

```
Router / Controller     thin — params, call one context function, render. No queries, no rules.
        │
Context (Core.*)        the public API of a domain. Joins an engine's decision and Data.* writes in ONE transaction.
        │
Engine (Core.*, pure)   decides. Data in, decision out; takes `now` as an argument. No Repo.
        │
Data.*                  schemas, changesets, composable queries, the writes.
        │
Repo
```

Off to the side:

```
Workers (Oban)          scheduled and background work. Call contexts; hold no rules.
Access                  can?(scope, action, resource) — one module, every check (P1).
```

| Layer | Does | Never |
|---|---|---|
| Controller | Cast params, call one context function, render | Query, branch on business rules, touch Repo |
| Context | Enforce rules, orchestrate, return `{:ok, _}` / `{:error, _}` | Know about conn, params or HTTP |
| Engine | Decide, purely | Touch the Repo, the clock or the network |
| Schema | Fields, changesets, validation | Query, call other contexts |
| Worker | Schedule, retry, call a context | Contain the rule it is scheduling |

The split is enforced by the compiler: `data` cannot name a `core` module,
and the umbrella makes that a compile error rather than a review comment.

---

## 2. Scoping is the architecture

A customer must never reach another customer's rows; a member sees only what
their team's visibility settings allow (PLAN §3). That makes "whose data is
this, and how much of it" a question on **every read**, not a middleware
concern.

**Every context function takes `%Data.Scope{}` first.** No exceptions,
including private helpers that build queries.

```elixir
# Good
def list_leads(%Scope{} = scope, opts \\ [])

# Never
def list_leads(opts \\ [])
```

Rules:

- **No unscoped `Repo.all/2`.** If a job needs one, name it
  `list_all_leads_for_system/1` so it is obvious in review.
- **Field-level restriction happens in the context**, not the view.
- `Core.Access` (P1) is the only place role logic lives, and it is **pure**.
- **The scope lives in `data`**, because every data function takes one and
  `data` cannot depend on `core`. Only the decisions made with it are business
  logic.

---

## 3. Canonical units

| Quantity | Column | Notes |
|---|---|---|
| Money | `:integer` minor units + `currency` string | **Never** `:float` or `:decimal` for money in transit; `_minor` suffix |
| Timestamps | `:utc_datetime_usec` (`timestamptz`) | Plus the IANA zone it was set in, where a schedule is involved |
| Calendar days | `:date` | A day, not an instant |
| Duration | `:integer` seconds, or the unit in the name (`lead_days`) | |

The API speaks canonical units only. Conversion is the frontend's job at
render — that split is what stops rounding drift from accumulating in storage.

---

## 4. Verbs are endpoints

`POST /leads/:id/move`, `/hold`, `/finish`, `/archive`; `POST /tasks/:id/complete`
(PLAN §15.2, §15.4). Never `PATCH {state: "done"}`.

Each verb is **one transaction** that writes the change, the History event,
the audit row and the notifications. A status patch would put those in the
client, where the next client reimplements them.

---

## 5. The error shape

**One shape, everywhere, through `ApiShared.FallbackController`** (PLAN §15.5).

```json
{"error": {"code": "not_found", "message": "We could not find that.", "details": {}}}
```

**The `code` is the contract. The `message` is for humans and may be reworded
at any time.** The extension updates on the store's schedule, not ours, so it
will match on these codes for longest — and a client matching on English
prose breaks the first time somebody improves the copy.

`details` is `{}` unless there is something structured to say. For a 422 it
carries `{field => [message]}`.

### Codes in P0

| Status | `code` | When |
|---|---|---|
| 401 | `unauthenticated` | No token, expired, or forged |
| 403 | `forbidden` | Known resource, insufficient role |
| 404 | `not_found` | Missing **or** not yours — a scoped 404 beats a 403 for a row the caller may not know exists |
| 409 | `conflict` | A stale `lock_version` |
| 422 | `validation_failed` | `details` names the fields |
| 429 | `rate_limited` | `details.retry_after_seconds` when the throttle knows; the header `retry-after` too |
| 500 | `internal_error` | Says nothing about internals |

### Codes in P1 (JH-01 §6.5)

| Status | `code` | When |
|---|---|---|
| 401 | `invalid_credentials` | A wrong email **or** a wrong password: the same words for both; also a Google token that does not verify |
| 404 | `account_not_found` | Google proved an address no account has (QP1-5: nobody signs up uninvited) |
| 403 | `account_suspended` | Signing in to a suspended account (QP1-10); the person knows they have one |
| 401 | `invalid_refresh_token` | A refresh token that is spent, forged, expired, or not a refresh token |
| 404 | `invitation_invalid` | A code nobody issued, of the wrong shape, or revoked |
| 410 | `invitation_expired` | A code past its seven days (QP1-1) |
| 410 | `invitation_used` | A code already accepted |
| 422 | `password_too_weak` | Under ten characters, over bcrypt's 72 bytes, or on the worst-list (QP1-6); `details.password` |
| 410 | `token_invalid` | A reset or confirmation link that is dead: used, expired or never issued — one answer for all three |
| 409 | `email_taken` | An address another account already has: accepting an invitation without signing in, or an email change |
| 409 | `last_admin` | Revoking the organisation's only admin: "The organisation needs one admin. Grant another first." |
| 403 | `role_above_yours` | A lead making or touching a manager: "Only a manager can make a manager." |
| 413 | `file_too_large` | Over the cap for the kind (QP1-3: 5 MB a photo, 10 MB a document); `details.max_bytes` |
| 415 | `file_type_not_allowed` | A content type off the allowlist, or wrong for the kind |
| 422 | `file_mismatch` | The bytes are not the declared type (sniffed, never trusted from the header) |
| 404 | `not_a_customer` | A staff account on the portal (P1.3: "This sign-in is for customers"); `ApiClient.Plugs.CustomerScope` raises it before any controller runs |

Two shapes carry `details` without a new code: `{:error, {:invalid, %{field => [message]}}}`
is a `422 validation_failed` for a body the context cannot act on as sent (a
profile `PATCH` mixing pitch and facts, a document with both `media_id` and
`url`), and `{:error, {:invitation_expired, expires_at}}` is the `410` with
`details.expires_at`, so the screen can say when.

### Reserved (PLAN §15.5), arriving with the phases that raise them

| Status | `code` | When |
|---|---|---|
| 409 | `duplicate_application` | A second application to the same job; `details.existing` names the lead |
| 422 | `override_reason_required` | Overriding the duplicate guard without saying why |
| 409 | `lead_moved` | The lead changed under you; reload |
| 422 | `outcome_required` | Finishing a lead without an outcome |
| 409 | `approval_not_pending` | Deciding an approval that is not pending |
| 403 | `not_reviewer` | Deciding an approval that is not yours to decide |
| 422 | `channel_unknown` | A capture from a channel nobody registered |
| 409 | `identity_mismatch` | The extension's identity is not the acting profile's |

**We do not use `{"success": false, ...}`.** An envelope restating the HTTP
status gives every client two places to check that can disagree, and it
carries no stable code.

**A new code is a new clause in the fallback and a new row here**, in the
same change. Inventing one at a call site is how a contract becomes a guess.
An `{:error, _}` with no clause is a 500 — the backstop working, and also how
a rule behaving exactly as designed tells people "Something went wrong at our
end" while every unit test stays green.

---

## 6. The socket

The socket is **not an alternative to the API** (PLAN §15.6). An event carries
an **id**, the client turns it into `invalidateQueries`, and the re-read goes
over HTTP where the scope restricts properly. A client is never handed a row,
so a broadcast cannot leak a staff-only field. **Nothing is ever written over
a channel.**

### Broadcast after commit, through the endpoint

```elixir
# Good
Repo.transaction(fn -> ... end)
|> Core.Broadcast.after_commit(fn lead ->
  Core.Broadcast.broadcast("lead:" <> lead.id, "lead_moved", %{lead: lead.id})
end)

# Never — looks equivalent, is not
Phoenix.PubSub.broadcast(Core.PubSub, topic, %Phoenix.Socket.Broadcast{...})
```

`after_commit/2` takes the transaction's return value, so a rollback
broadcasts nothing. `Endpoint.broadcast/3` attaches the **fastlane**; a raw
publish lands in every channel process's mailbox and routes through a
`handle_out/3` the channels do not define — which crashed every broadcast to a
joined client in AutoCare, silently, because the client reconnects and
refetches. The endpoint is injected as `config :core, :endpoint` because `api`
depends on `core` and never the reverse.

### Both halves in the same change

An event the server emits that no client handles is dead code; one the client
handles that no server emits is a board that never updates. When you add an
event, add its handler in the frontend's `packages/core` realtime module in
the same change.

A channel test that subscribes to PubSub proves nothing about channels: use
`Api.ChannelCase` and `subscribe_and_join/3`, and assert with `assert_push`.

---

## 7. Notifications are rows

`core` decides what to say and **writes a notification row in the same
transaction** as the change. `notifire` picks up unsent rows and delivers them
(P7). The table is the seam: a mailer being down leaves rows unsent rather
than failing the write that produced them.

- `core` and `notifire` **never call each other**. A worker `notifire` owns is
  named to `core` in config (the crontab, a job's `worker:`), never in code.
  Config is not a dependency.
- Build such a job with `Oban.Job.new/2`, never `Worker.new/1`: the generated
  `new/1` needs the module loaded, and `apps/core`'s own suite is exactly
  where it is not.
- Notifications are `ensure`d against a `dedupe_key`, never blindly created.

---

## 8. Background work (Oban)

Queues are named by purpose with deliberate concurrency (`config :core, Oban`;
PLAN §15.7): `scheduling`, `retention`, `notifications`, `emails`, `push`,
`ingest`, `behaviour`, `ai`.

**Every worker is idempotent and takes `now`.** They run on a schedule, on
deploy, and after any backfill, so each has a test that runs it twice. Workers
hold **no rules**: they call a context function a test can call directly.
`testing: :manual` in test — a job racing the SQL sandbox produces failures
that have nothing to do with the code under test.

---

## 9. Naming

| Type | Convention | Example |
|---|---|---|
| Modules | PascalCase, context-first | `Core.Leads.Act` |
| Functions | snake_case, verb-first | `list_leads/2`, `move_lead/3` |
| Predicates | `?` suffix | `overdue?/1`, `can?/3` |
| Bang variants | only where raising is genuinely right | `get_lead!/2` |
| Booleans | `is_` / `has_` / `can_` / `allow_` | `is_active`, `has_cv` |
| Timestamps | `_at`, and it **must** be a timestamp | `archived_at`, `applied_at` |
| Dates | `_on` or `_date`, never `_at` | `follow_up_on` |
| Money | `_minor`, integer | `rate_minor` |
| Type discriminators | prefixed with the entity | `meeting_kind`, never bare `type` |
| Tables | **plural, always** | `leads`, `tasks` |
| Child and join tables | singular parent + plural child | `lead_events`, `team_members` |
| Discriminator values | singular, naming a thing | `screening`, `offer` |
| Discriminator columns | an `Ecto.Enum` **and a `CHECK` named `<field>_known`** | `kind IN ('screening', …)` |
| Migrations | verb + subject | `create_leads` |

**`_at` versus `_on` is not cosmetic.** `Date.diff/2` and `DateTime.diff/2`
take different structs, so a `:date` called `expires_at` is a
`FunctionClauseError` at runtime. `Core.ConventionsTest` fails on either
direction.

**An `Ecto.Enum` with no `CHECK` behind it** is an application-level check
wearing a database's clothes: the constraint is what stops a mix task or a
psql session writing something the code cannot read.

The values themselves are `Data.Vocabulary`'s, shared with the frontend word
for word and in order; `mix jh.vocabulary` exports them.

---

## 10. Migrations

Four rules; `Core.ConventionsTest` fails on the first three.

1. **One `create table` per file.** A migration creating several cannot be
   reviewed, reverted or reordered on its own, and half-applies when one fails.
   Indexes, constraints and the `touch_updated_at` trigger belong with it.
2. **Generate the file**: `mix ecto.gen.migration create_leads --migrations-path apps/data/priv/repo/migrations`.
   Re-time it by hand only where the position is load-bearing (a foreign key
   must not precede the table it points at).
3. **No `alter table`, because nothing is deployed** (PLAN §15.2). A column is
   added by **editing the `create` migration**, then `mix ecto.reset` **and**
   `MIX_ENV=test mix ecto.reset`. An `alter` in a pre-production repo is almost
   always a schema that wants rearranging.
4. **No backfills.** `mix ecto.reset` working from scratch is the property
   everything above depends on. Data belongs in a seed task (`Data.Seeds`).

**All of this inverts on the first production deploy**, when forward-only
becomes the rule and the guard tests are deleted with it.

---

## 11. Tests

- **Co-located**: `foo.ex` / `foo.test.exs`, beside the source, in every app.
  `test/support` holds the cases (`DataCase`, `CoreCase`, `ConnCase`,
  `ChannelCase`) and `Data.Fixtures`. A file named `*_test.exs` matches
  nothing, runs zero cases and reports success — `Core.ConventionsTest` fails
  on any.
- **Every context function has a test, including the scoping.** A test that
  proves a customer cannot read another customer's lead is worth more than ten
  changeset tests.
- Fixtures take a scope, so test data that could not exist in production
  cannot be built.
- Name tests after the behaviour: `test "a rolled-back write broadcasts nothing"`.
- `mix precommit` is the gate: compile with warnings as errors, format,
  `credo --strict`, test.

---

## 12. Dependencies

**Every third-party dependency goes in `apps/utils/mix.exs`.** Individual apps
declare `in_umbrella` deps and nothing else; `Core.ConventionsTest` holds it.

```elixir
# apps/core/mix.exs — right
defp deps do
  [{:data, in_umbrella: true}, {:utils, in_umbrella: true}]
end
```

The hub has to be the app everything already depends on, and the direction is
`utils ← data ← core ← api_shared ← api_* ← api`. Two files declaring the same
dependency is two versions waiting to disagree. `req` is the house HTTP client
— never httpoison, tesla or httpc. `utils` stays pure in its **code**: it
names none of them.

---

## 13. Before you finish

```bash
mix precommit
```

Fix everything it reports. Leave no server running.
