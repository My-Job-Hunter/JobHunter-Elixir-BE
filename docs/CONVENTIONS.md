# AutoQare Backend — Conventions

The enforced rules for this codebase, adapted from mCart's. `CLAUDE.md` is
the index; `AGENTS.md` covers Phoenix mechanics; `../PLAN.md` is the product.
This covers AutoQare's own decisions.

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
- **The extension acts as its person** (AQ-05 QP5-6): the same scope with
  `via: :extension`, the same `Core.Access`, guard and verbs — no second
  rulebook. Its ledger rows are `actor_kind: extension` with the person, and
  count as activity.
- **A token stays in its app** (AQ-05 QP5-5): a device's (`dev.app` `ext`,
  `sid` the device) works only on `/ext/v1`, and no other token works there
  (`ApiShared.Plugs.TokenApp`, `Guardian.exchange_refresh_token/2`).
- **What only the server sets is an option, never a param**: the
  extension's `request_id`, `applied_confirmation` and capture reach
  `Core.Leads.create/4` and `Core.Leads.Act.run/6` as `opts`, so no console
  body can claim them.

---

## 3. Canonical units

| Quantity | Column | Notes |
|---|---|---|
| Money | `:integer` minor units + `currency` string | **Never** `:float` or `:decimal` for money in transit; `_minor` suffix. A minor unit is **ISO 4217's exponent** (2 for PKR and USD, 0 for JPY, 3 for KWD), never a browser's display rule: the frontend's `minorDigits` holds the same table |
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

### Codes in P1 (AQ-01 §6.5)

| Status | `code` | When |
|---|---|---|
| 401 | `invalid_credentials` | A wrong email **or** a wrong password: the same words for both; also a Google token that does not verify |
| 404 | `account_not_found` | Google proved an address no account has (QP1-5: nobody signs up uninvited) |
| 403 | `account_suspended` | Signing in to a suspended account (QP1-10); the person knows they have one |
| 401 | `invalid_refresh_token` | A refresh token that is spent, forged, expired, or not a refresh token |
| 404 | `invitation_invalid` | A code nobody issued, of the wrong shape, or revoked |
| 410 | `invitation_expired` | A code past its seven days (QP1-1) |
| 410 | `invitation_used` | A code already accepted |
| 422 | `password_too_weak` | Under ten characters, over bcrypt's 72 bytes, or on the worst-list (QP1-6); `details.password`. A dev server skips the worst-list (`config :core, dev_worst_passwords: true`, dev.exs only), so the cast's shared test password works there |
| 410 | `token_invalid` | A reset or confirmation link that is dead: used, expired or never issued — one answer for all three |
| 409 | `email_taken` | An address another account already has: accepting an invitation without signing in, or an email change |
| ~~409~~ | ~~`last_admin`~~ | **Retired in P4a.0** (AQ-04A QP4a-21): there is one system admin and no route revokes it, so nothing raises it; the fallback clause is gone |
| ~~403~~ | ~~`role_above_yours`~~ | **Retired in P4a.0** (AQ-04A §4.0): there is no manager; a team lead touching a role or another lead is `forbidden` with "Only the system admin can do that."; the fallback clause is gone |
| 413 | `file_too_large` | Over the cap for the kind (QP1-3: 5 MB a photo, 10 MB a document); `details.max_bytes` |
| 415 | `file_type_not_allowed` | A content type off the allowlist, or wrong for the kind |
| 422 | `file_mismatch` | The bytes are not the declared type (sniffed, never trusted from the header) |
| 404 | `not_a_customer` | A staff account on the portal (P1.3: "This sign-in is for customers"); `ApiClient.Plugs.CustomerScope` raises it before any controller runs |

Two shapes carry `details` without a new code: `{:error, {:invalid, %{field => [message]}}}`
is a `422 validation_failed` for a body the context cannot act on as sent (a
profile `PATCH` mixing pitch and facts, a document with both `media_id` and
`url`), and `{:error, {:invitation_expired, expires_at}}` is the `410` with
`details.expires_at`, so the screen can say when.

### Codes in P2 (AQ-02 §7.5)

| Status | `code` | When |
|---|---|---|
| 409 | `task_moved` | A task verb whose `from` is not the task's state now (`{:error, {:task_moved, task}}`): "This task moved while you were looking. It's now In progress."; `details: {state, stage}` as it is now, `stage` `{id, name}` or `null` |

Everything else the board refuses is a field error (422) or `not_found` /
`forbidden` with AQ-02 §6.2's words ("Only the people on this task, or a
lead, can change it.", "This task isn't about a customer."). AQ-03B removed
`is_private` (and its words): sending it is a 422 on the field.

### Codes in P3 (AQ-03 §7)

| Status | `code` | When |
|---|---|---|
| 409 | `job_exists` | `POST /jobs` with a link whose canonical key is a job's already, or was merged into one — including a job added between the check and the insert (`{:error, {:job_exists, job}}`): "That link is already in the pool: Backend Developer."; `details: {job_id, title}` of the job it is (the survivor, for a merged link). Per team since AQ-03B: the key is the team's pool's; a job the caller may not see (a teammate's at `peer_jobs: hidden`) is `{:error, {:job_exists, :hidden}}` — the same code, "That link is already in this team's pool, added by another member.", `details: {job_id: null, title: null}` |
| 409 | `job_moved` | A close or reopen whose `from` is not the job's status now (`{:error, {:job_moved, job}}`): "This job changed while you were looking. It's now closed."; `details: {status}` as it is now |

Everything else the pool refuses is a field error (422) or `not_found` /
`forbidden` with AQ-03 §4.2's words ("Only a lead can merge or archive a
job."). The customer reaches no job or company: `not_found`.

### P3b (AQ-03B §5): no new code

A teammate's task or job hidden by the team's level, a team the caller is
not in, and a share link that is unknown, expired, revoked or opened by a
customer or another organisation are all `not_found`. A member at `view`
is refused a change with `forbidden` and "You can see this, but only its
people or a team lead can change it."; a share link's revoke by anyone but
its maker, a team lead or an admin with "Only whoever made this link, or a
team lead, can turn it off." A list, a check or a create without `team_id`,
a `view` on `GET /board`, `is_private` on a task, a merge into another
team's job (`into_job_id` "is in another team") and a task moved to another
team (QT-12) are field errors (422).

### P4a (AQ-04A §4.0, §6, §7, §8.4, §8.5)

| Status | `code` | When |
|---|---|---|
| 409 | `duplicate_application` | `POST /leads` (or an apply) for a profile that already has a lead on the posting, in any team (`{:error, {:duplicate_application, %{existing, message}}}`): "“Golang” already has a lead on this job: applied by Fiza, 12 Oct." — in another team "…in another team, applied 12 Oct.", for a lead the caller may not see "…by another member, 12 Oct."; `details: {existing: {lead_id?, state?, applied_at, by?, team: "this" \| "another"}}`, the keys the caller may not know left out. The unique `(job_id, profile_id)` maps to the same 409 |
| 422 | `override_reason_required` | *Apply again* without a `reason`: "Say why you're applying again."; `details: {reason: ["is required"]}` |
| 409 | `lead_moved` | A lead verb whose `from: {state, stage}` is not where the lead is now (`{:error, {:lead_moved, lead}}`): "This lead moved while you were looking. It's now In progress · Technical interview 1."; `details: {state, stage: {key, name}?}` |
| 422 | `outcome_required` | *Finish* (or a drop on Done) without an `outcome`: "Say how it ended."; `details: {outcome: ["is required"]}` |

Everything else a lead refuses is a field error (422) — a paused customer or profile on `profile_id` ("Naveed is paused. Resume them before saving or applying for them."), a pipeline save off §9.2's rules on `stages`, a merge with a profile on both jobs on `into_job_id` — or `not_found` / `forbidden` with AQ-04A §4.2's words ("Backend squad doesn't serve Imran.", "You can see this, but only its owner or a team lead can change it.", "Only the owner or a team lead can hand this lead on.", "Only the lead's owner, or a team lead, can archive or pin it.", "Only a team lead can change a pipeline.", "You can say you applied while it is still To do.").

**The roles (P4a.0, AQ-04A §8.5)** raise no code of their own: what is the system admin's alone — teams, roles, Settings › System, the audit log, inviting a team lead — is `forbidden` with "Only the system admin can do that."; a customer put in a team the caller only works in is `forbidden` with "Only a lead of that team can add a customer to it."; `kind: admin` on `POST /invitations` and a missing `team_ids` on `POST /customers` are field errors (422).

### P4b (AQ-04B §4, §8.4): no new code

Every refusal is a field error (422), `not_found`, a `forbidden` with
AQ-04B §4's words ("Only the people working this lead can add a note.",
"Only its author or a team lead can change a note.", "Only a team lead can
change the team's labels.", AQ-04A §4.2's for following up, labelling and a
task on a lead), or P4a's `lead_moved`. A purged pair answers P4a's 409
`duplicate_application` with `details.existing.purged: true` and "Already
applied as “Golang” on 16 Oct; that lead was cleared after 180 quiet
days."; *Apply again…* there (`again_reason` on `POST /leads`) without a
reason is P4a's 422 `override_reason_required`. A note, the retention
preview, Customer › Activity for staff and another person's saved view are
`not_found`. `POST /leads/bulk` answers 200 with each lead's refusal as
`{id, code, message}` — the same codes and words, from
`ApiShared.FallbackController.describe/1`, never a status of their own.

### P5 (AQ-05 §8, §11.3, §11.4)

| Status | `code` | When |
|---|---|---|
| 409 | `identity_mismatch` | *I applied* (`POST /ext/v1/leads/applied`) with an `identity` that is a live channel of another customer than the acting profile's (`{:error, {:identity_mismatch, %{channel, kind, acting}}}`): "You're signed in as Naveed's LinkedIn, not Tanweer's. Switch the acting profile, then press again."; `details: {channel: {id, customer: {id, display_name}}}` — `channel: null` (and "…signed in to another customer's LinkedIn…") for a channel of a customer the caller doesn't serve. *Save* is never refused for it (QP5-9) |

Everything else the extension meets is P1's, P3's or P4a's: a dead, used or
unknown connect code is P1's 410 `token_invalid` (one answer for all
three); a token of the wrong app — a device's on `/team` or `/client`, a
console's or portal's on `/ext`, or a disconnected device's — is the
pipeline's `401 unauthenticated`, and its refresh `401
invalid_refresh_token`; `job_exists`, `duplicate_application`,
`override_reason_required`, `lead_moved` and field errors as the console
gets them. A device, the health page and the configs list of someone the
caller may not see are `not_found`. `GET /ext/v1/config` answers `304` with
no body when `If-None-Match` names its `ETag` (the document's SHA-256,
quoted) — a cache answer, not an error. **Idempotency:** a save, applied
or apply-again whose `request_id` already made an event answers `200`
`answer: "replayed"` with that lead (`lead_events.request_id`, unique),
never the guard's 409.

### P6 (AQ-06 §6, §11.6)

| Status | `code` | When |
|---|---|---|
| 409 | `contact_exists` | `POST /contacts` (the match re-run in its transaction) or `POST /contacts/:id/handles` with a handle — an email, a LinkedIn or Upwork link by `Utils.ChannelKey`, a phone's digits, normalised — that another contact holds (`{:error, {:contact_exists, %{contact_id, name, kind}}}`): "That LinkedIn is Mei Chen's already."; `details: {contact_id, name}` of the contact holding it (the survivor, for a merged one) |

Everything else P6 refuses is a field error (422) — a verb on a meeting not
scheduled on `status` ("This meeting is already cancelled."), *Create job
and lead* without a link on `job.url` ("Add the job's link."), a class
needing a lead on a triage item, a conversation linked across teams or
customers — `not_found` (an unseen conversation, message or meeting; a
customer on a contact, triage or a staff note), or `forbidden` with AQ-06
§4's words ("Only a team lead can merge contacts.", "Only its author or a
team lead can change this message.", "Captured messages can't be
edited.") and P4a's for whoever may not change the lead.

### P7 (AQ-07 §4, §11.4)

| Status | `code` | When |
|---|---|---|
| 409 | `approval_not_pending` | `POST /approvals/:id/decide` on a `version` that isn't the current one, an approval no longer pending, or a slot that has decided this version already — re-checked under a row lock in the decision's transaction (`{:error, {:approval_not_pending, %{state, version}}}`): "This approval changed while you were looking. It's now Changes requested."; `details: {state, version}` as it is now |
| 403 | `not_reviewer` | Deciding an approval the caller sees but holds no slot of — staff on a customer's slot, a member on a team-lead slot, and the requester on their own (`{:error, :not_reviewer}`): "This isn't yours to decide." |

Everything else P7 refuses is a field error (422) — an ad hoc kind without
`slots`, a `proposed.<member>` that doesn't fit the kind, a note missing on
`changes_requested` or `rejected`, a verb in the wrong state on `state`
("Only a draft can be edited; revise it instead."), `sent` twice on
`effect` — `not_found` (an unseen approval or draft; a customer on a
staff-only one; a profile change asked by staff not serving the customer),
or `forbidden` with AQ-07 §4's words ("Only whoever asked, or a team lead,
can change this.", "Only a team lead can change approval rules.", "Only its
author or a team lead can delete this comment.", "Only a team lead can see
all of the team's approvals.") and P4a's for whoever may not change the lead.

### P8 (AQ-08 §4, §11.4): no new code

Every refusal is a field error (422) or P1's codes: `PUT
/notifications/settings/groups/:key` on Account (`group`: "These can't be
turned off."), on a channel the group doesn't use ("This group doesn't use
it."), on `extension` for a customer ("The extension is for the team."), on
a switch that isn't a boolean; `POST /me/push` with a missing key or an
endpoint not `https://` (`endpoint`: "This browser's subscription didn't
come through."); an unknown group is `not_found`; delivery health for
anyone but the system admin is `forbidden` with "Only the system admin can
see delivery health."; a console or portal token on
`/ext/v1/notifications/pop-ups` is P5's `401 unauthenticated`.

### P9 (AQ-09 §4, §11.4)

| Status | `code` | When |
|---|---|---|
| 409 | `meeting_not_proposed` | `POST /meetings/:id/confirm` or `/dismiss` on a meeting with nothing waiting for a person — not `proposed`, and no proposed change (`{:error, {:meeting_not_proposed, meeting}}`): "This meeting isn't waiting for a confirmation."; `details: {status}` as it is now |
| 503 | `inbound_off` | `POST /inbound/email` on a server with no `INBOUND_PASSWORD` (`config :core, :inbound, password:`): "Forwarded mail isn't set up on this server." |
| 401 | *(no body)* | `POST /inbound/email` with a wrong basic-auth pair, or none (`{:error, :inbound_unauthorised}`): `www-authenticate: Basic realm="inbound"`, an empty body (AQ-09 §4) — the provider's request, not a person's |

Everything else is P1's or a field error: the webhook over 30 MB is P1's
413 `file_too_large` (`details.max_bytes`); one address flooding it is the
429 `rate_limited`; *New address* on a channel that isn't email is a 422
on `kind` ("Only an email channel has a forwarding address."), and by
staff owning none of its profiles `forbidden` with "Only the customer's
leads and owners can change it."; a verb on a proposed meeting other
than *Confirm* · *Dismiss* is a 422 on `status` ("This meeting is only
proposed: confirm it first."). **The webhook answers 200 for every mail
it accepted** — an unknown address and an unreadable mail included
(QP9-7) — with `{outcome}`.

### Reserved (PLAN §15.5), arriving with the phases that raise them

| Status | `code` | When |
|---|---|---|
| 422 | `channel_unknown` | A capture from a channel nobody registered (P6's conversations) |

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
joined client in mCart, silently, because the client reconnects and
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
transaction** as the change, through `Core.Notifications.ensure/2`, which
plans the new row's deliveries in that transaction too: one
`notification_deliveries` row per channel beyond the bell (AQ-08 §7.1).
`notifire` sends the due ones (`Notifire.Delivery.run/2`, on write and every
five minutes). The ledger is the seam: a mailer being down leaves rows
pending rather than failing the write that produced them, and the unique
`(notification_id, channel)` is "never twice".

- `core` and `notifire` **never call each other**. A worker `notifire` owns is
  named to `core` in config (the crontab, a job's `worker:`), never in code.
  Config is not a dependency.
- Build such a job with `Oban.Job.new/2`, never `Worker.new/1`: the generated
  `new/1` needs the module loaded, and `apps/core`'s own suite is exactly
  where it is not.
- Notifications are `ensure`d against a `dedupe_key`, never blindly created,
  and only through `Core.Notifications.ensure/2` (P8): a notice module that
  called `Data.Notifications.ensure/2` would skip its deliveries.
- What `notifire` needs from `core` it gets as data on the row: a meeting's
  `.ics` is rendered by `core` and kept on the email row (`ics`), never
  read back through a `core` call.

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

**The sweeps are hourly, never "once a night"** (AQ-04B QP4b-2; P5's
`Core.Extension.MissSweep` too, which forgets misses after 30 days): a rule
that compares dates does the night's work once in whichever hour comes
first, and catches up after downtime with no time-zone cron to keep right.

**The dev clock** (AQ-04B §7.6): `Core.Clock.now/0` (a delegate to
`Utils.Clock` since AQ-08 QP8-22, so `notifire` reads the same *now*) adds
an offset in days kept in `:persistent_term`, set only by `POST /team/v1/dev/clock {days}` (and
`/dev/clock` at the root) on a server built with `config :api, dev_routes:
true` — and refused unless `config :core, dev_clock: true`, both dev.exs's
alone — so a release has no route and an offset of 0. `freeze/1` still wins
in a test; a test that moves the offset is `async: false` and resets it on
exit.

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
for word and in order; `mix aq.vocabulary` exports them.

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
