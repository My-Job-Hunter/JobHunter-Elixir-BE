# Claude Instructions — AutoQare Backend

The Phoenix API behind AutoQare: the team console, the customer portal and
the Chrome extension. **The product and the build plan live in
[`../PLAN.md`](../PLAN.md)** — the domain, the phases (§18), the rules that
bind (§20). This file says how to work in *this* repository; it does not
restate the plan.

**State: P0–P9 done** (P9 run 2026-11-12, `../docs/runs/AQ-09-RUN.md`; 2026-11-12, `../docs/phases/AQ-09-EMAIL.md` as pinned in §11.4: `inbound_token` on email channels and the address from `config :core, :inbound`; `POST /inbound/email` (`Api.InboundController`, basic auth, 30 MB on that route alone in `Api.Endpoint.parse/2`) and `POST /dev/inbound`; `Core.Inbound` (+ `Address`, `Postmark`, `Gmail`, pure) logging every delivery in `inbound_messages` (30 days, `Core.Workers.InboundSweep`); `Core.Conversations.Forward` landing through `Inbox.land/8` with the receiving channel; AQ-09 §7 in `Core.Conversations.Match` and `Platforms`; Gmail's check in `channel_confirmations`; invitations read by `Core.Meetings.Ical` and `Invite` (pure) and proposed by `Core.Meetings.Proposals` (`proposed`, *Confirm* · *Dismiss*); 32 notification kinds); its run (P9.6) is next. (P8 2026-11-12, `../docs/runs/AQ-08-RUN.md`; the standard test users in `docs/TEST-ACCOUNTS.md`; `../docs/phases/AQ-08-DELIVERY.md` as pinned in §11.4: `Utils.Clock` with `Core.Clock` delegating; `notification_preferences`, `push_subscriptions`, `notification_deliveries`; the seam `Core.Notifications.ensure/2` with the pure `Channels.plan/5`, `QuietHours`, `Digest` + `Digests` and `Core.Workers.DigestScan`, `Settings`, `Push`, `PopUps`, `Health`; the seven notice modules on the seam; `leads.customer_milestone`, `meetings.day_before`, the customer told of replies; `notifire`'s sweep, push and email; the reference seed's 30 kinds updated in place). (P7 2026-11-12, `../docs/runs/AQ-07-RUN.md`: approvals with slots, versions and a diff, each kind's effect through the existing verbs, policies, due, expiry and auto-approve). P7's backend notes (2026-11-12, `../docs/phases/AQ-07-APPROVALS.md`: approvals with versions, files, reviewer slots and decisions per version, comments and customer policies with Q12's defaults as code; the verbs in `Core.Approvals.Act`, the pure `Rule` and `Diff`; each kind's effect through P4a's and P1's verbs; due reminders, auto-approve and the hourly expiry; 409 `approval_not_pending`, 403 `not_reviewer`); its screens (P7.4) and run (P7.5) are next. (P6 2026-11-12, `../docs/runs/AQ-06-RUN.md`: contacts with matching and merge, conversations threaded by hand and from `.eml` (`mail`), triage derived and *Classify* through P4a's verbs, meetings with reminders (`Core.Workers.MeetingReminder`), ICS and the clash, the portal's meetings and conversations without the team's name, `/ext/v1/conversations/capture`). **P5 built and run** (2026-11-11, `../docs/runs/AQ-05-RUN.md`: devices and connect codes, tokens kept in their app, `/ext/v1`, the acting profile, lookup, capture, save, applied with `request_id`, signals, selector configs and health; the real-page step is paused, the rest done). **P6's backend built** (2026-11-11, `../docs/phases/AQ-06-CONVERSATIONS.md`: contacts with handles, the match and merge; conversations and messages as trees, by hand, from `.eml` (the `mail` package) and captured by the extension; triage derived; *Classify* through P4a's verbs; meetings with reminders, the clash and ICS; retention's cascade); its run (P6.6) is next. A dev server accepts the cast's shared test password `password123` (`config :core, dev_worst_passwords: true`); test and a release keep the worst-list. (P4b 2026-11-11, `../docs/runs/AQ-04B-RUN.md`: the lead page, the Tracker with saved views, labels, CSV and bulk; follow-ups; retention with the dev clock, the hourly sweeps and tombstones). (P4a 2026-11-11, `../docs/runs/AQ-04A-RUN.md`: one system admin, team leads and staff, no manager; pipelines with versions; leads and their ledger; the guard across teams; both boards; the portal's *My applications*). (P3b 2026-11-11, `../docs/runs/AQ-03B-RUN.md`: every job and task in one team; `peer_tasks` · `peer_leads` · `peer_jobs` ∈ hidden · view · edit; one board and one pool per team; share links; the dev data rebuilt by `mix aq.world`). (P3 done 2026-11-10; records `../docs/runs/AQ-0{1,2,3}-RUN.md`).
P2 (`../docs/phases/AQ-02-BOARD.md`) added the board and the bell: fourteen
tables, tasks with their verbs (`from`, 409 `task_moved`), notifications
ensured by dedupe key, `Core.Workers.TaskDueScan`, the `user:` · `team:` ·
`customer:` channels (`team_settings_updated` among them). P3
(`../docs/phases/AQ-03-JOBS.md`) added the job pool: `Utils.JobKey` (the
canonical key per platform, every vector a test), ten tables, the check
(`POST /jobs/check`, its job half; P4a adds the lead half), merge into a
survivor that keeps the merged key, `Core.Jobs.Suggest` (the score, computed
on read), `Core.Access.Jobs` + `Core.JobAccessMatrixTest`, and 409
`job_exists` / `job_moved`. Money's minor unit is ISO 4217's (CONVENTIONS
§3).

## Git is the user's

**Never run git here** — not commit, stage, stash, branch, tag, push or reset,
and not the read-only ones either (status, diff, log, show). The user reviews
the working tree and does every git step themselves. Nothing in the build runs
git either: `Api.InfoController` reports no commit for that reason.

## Read these first

| Doc | For |
|---|---|
| **[`../PLAN.md`](../PLAN.md)** | The product, the data model, the phases. The domain is defined there, not here. |
| **[AGENTS.md](./AGENTS.md)** | Phoenix 1.8 framework rules — Ecto, HEEx, forms. Generic to Phoenix; **still binding**. |
| **[docs/CONVENTIONS.md](./docs/CONVENTIONS.md)** | This app's own rules — scoping, canonical units, the error shape, migrations, tests. |
| **[`../docs/p0/P0-BACKEND-BRIEF.md`](../docs/p0/P0-BACKEND-BRIEF.md)** | What P0 was asked to build, and the contract with the frontend. |

`AGENTS.md` wins on framework mechanics; `CONVENTIONS.md` wins on domain
decisions; `PLAN.md` wins over both.

## Ports and databases

Everything stays clear of mCart (4001, 5720–5729, `mcart_*`, Postgres on 5433), which may
be running on the same machine.

| What | Where |
|---|---|
| This API | **4100** (`AQ_PORT`); 4102 in test, never started |
| The team console (Vite) | 5800 |
| The customer portal (Vite) | 5801 |
| Postgres | localhost:5432 (`AQ_DB_PORT`), `postgres` / `postgres` |
| Databases | `autoqare_dev`, `autoqare_test` (+ `MIX_TEST_PARTITION`) |

**Testing from another device on the network:** set `LOCAL_IP` in the workspace's `../.env` (see
`../.env.example`; `ipconfig getifaddr en0`) and restart. The `aq-backend` launcher sources it, and
`config/dev.exs` then listens on every address, allows the apps at `http://<LOCAL_IP>:5800` and
`:5801`, and points email and invitation links there. Empty, everything stays on localhost.

The reference implementation is mCart at `../../mCart/mCart-BE-Elixir`.
**Read-only**: copy from it, never change it.

## The shape

```
utils ← data ← core ← api_shared ← api_team · api_client · api_ext ← api
                 ↑
              notifire   (a sibling of core; neither calls the other)
```

| App | Holds |
|---|---|
| `utils` | **every hex dependency** (`apps/utils/mix.exs`), and pure helpers (`Utils.SafeUrl`; P3: `Utils.JobKey` — a job link's canonical key and the similar-title rule — and `Utils.Units`, money periods to a year; P4b: `Utils.Money`, money as written with its currency, ISO 4217's minor digits; P5: `Utils.ChannelKey`, an account's link to its identity key; P6: `mail`, the `.eml` parser; P7: `earmark`, a version's markdown) |
| `data` | `Data.Repo`, `Data.Schema` (UUIDv7, `timestamptz`), `Data.Scope`, `Data.Vocabulary`, `Data.Seeds` (+ `Skills`, `Notifications`), migrations, the schemas and storage contexts (`Data.Accounts`, `Data.Organisations`, `Data.Teams`, `Data.Invitations`, `Data.Audit`, `Data.Files`, `Data.Customers`, `Data.Profiles`, `Data.Channels`, `Data.Documents`, `Data.Skills`; P2: `Data.Tasks` (+ `visible/2`, §6.1 as a query), `Data.TaskParts`, `Data.TaskComments`, `Data.TaskHistories`, `Data.TaskStages`, `Data.Notifications`; P3: `Data.Companies`, `Data.Jobs`, `Data.JobParts` (skills, snapshots, platform details, merges, dismissals), `Data.JobList` (§7.1's filters and sorts by keyset, one team's pool); P3b: `Data.ShareLinks`; P4a: `Data.Pipelines` (versions, stages and the §9.1 defaults as code), `Data.Leads` (leads, the ledger `lead_events`, the posting reads, the advisory lock; P4b: History's keyset, the signal events); P4b: `Data.LeadNotes`, `Data.Labels` (labels, `lead_labels`), `Data.SavedViews`, `Data.Retention` (the sweeps' candidates, `lead_fingerprints`, the deletes); P5: `Data.Devices`, `Data.Extension` (selector versions, misses), `Data.Jobs.Signal`, `Data.Seeds.ExtensionConfigs` (v1 of each site, reference); P6: `Data.Contacts` (contacts, handles normalised in `Handle`, merges, `lead_contacts`), `Data.Conversations` (conversations, links, participants, messages, `message_media`, triage as a query, retention's reads), `Data.Meetings` (meetings, attendees, the clash's and *Next*'s reads); P7: `Data.Approvals` (approvals, versions and their media, slots, decisions, comments, policies; the reminders', expiry's, *Next*'s and retention's reads)), `Data.Mail.Command`, the `aq.seed_*` mix tasks |
| `core` | the contexts (`Core.Accounts` + `Recovery` + `Device`, `Core.Organisation` + `Teams` + `Invitations`, `Core.Customers` + `Profiles` + `Channels` + `Documents` + `Notes` + `Skills` + `Portal`, `Core.Media` + `SweepWorker`, `Core.Audit` + `Labels`; P2: `Core.Tasks` + `Act` (the verbs, archive, delete) + `Board` + `Cards` + `People` + `Checklist` + `Steps` + `Links` + `Files` + `Comments` + `Histories` + `Notices` (who is told, in whose words) + `Stages` + `Portal` (§9) + `Due` + `Visibility` + `Write`, `Core.Notifications`, `Core.Realtime` (topics, joins, events), `Core.Workers.TaskDueScan`; P3: `Core.Jobs` (read, create with the check re-run in its transaction, edit, platform details) + `Act` (close, reopen, archive, unarchive, merge, dismissals) + `Check` + `Pool` (the list) + `Suggest` (the score, pure) + `Sheet` (the shapes) + `Regions`, `Core.Companies`; P3b: `Core.ShareLinks` (make, list, revoke, open at a level; P4a: leads too); P4a: `Core.Leads` (read, create, a new job in the same transaction) + `Act` (the moving verbs, `from`, 409 `lead_moved`) + `Change` (archive, pin, assign, CV, pipeline, edit) + `Moves` + `Guard` (the duplicate guard by posting, across teams) + `Board` + `Sheet` (the shapes; the customer's view cut here) + `Ledger` + `Notices` + `Pipelines` + `Portal` + `Words`; P4b: + `Next` and `FollowUps` (pure) + `Signals` (*Next*, follow-ups, the quiet clock and labels for a set of leads) + `FollowUp` (*Log follow-up*, the scan) + `History` + `Notes` + `TaskLinks` (tasks on a lead) + `Labels` + `Tracker` (and its CSV) + `Bulk`), P4b: `Core.Retention` (the three sweeps, the preview) + `Core.Retention.Policy` (pure), `Core.SavedViews`, the workers `Core.Workers.LeadFollowUpScan` and `Retention{Warn,Archive,Purge}Sweep` (hourly); P5: `Core.Extension` (connect codes, devices, disconnect) + `Context` (the acting profile) + `Configs` (contract 1, versions) + `Health` + `MissSweep` (hourly), `Core.Ingest.Extension` (lookup, save, applied, apply again) + `Pool` (a pool job seen again) + `Normalize` + `Read` + `Money` + `Facts` (pure) + `Words` (the banner), `Core.Jobs.Capture` (snapshot and signals), `mix aq.ext_config`, `Core.ExtensionAccessMatrixTest`; P6: `Core.Contacts` (+ `Match`, pure; `LeadLinks`), `Core.Conversations` (the shapes, the customer's cut) + `Tree` (pure) + `Messages` (by hand) + `Eml` (pure) + `Inbox` (an `.eml` landed, threaded, matched) + `Record` (links and message events) + `Triage` + `Classify` + `Notices`, `Core.Ingest.Conversation` (+ `SentText`, pure: the extension's capture), `Core.Meetings` + `Sheet` + `Words` and `Ics` (pure) + `Reminders` + `Notices`, `Core.Workers.MeetingReminder`, `Core.Access.Conversations` + `Core.ConversationAccessMatrixTest` + `Core.MeetingAccessMatrixTest`; P7: `Core.Approvals` (reads, draft, edit) + `Act` (submit, decide, revise, withdraw, sent, auto-approve, expire) + `Ask` (a body read) + `Rule` and `Diff` (pure) + `Policies` + `Effects` + `Sheet` + `Notices` + `Comments` + `Reminders`, `Core.Markdown`, the workers `Core.Workers.Approval{Reminder,AutoApprove,ExpirySweep}`, `Core.Access.Approvals` + `Core.ApprovalAccessMatrixTest`; `Core.Tasks.Write.commit/1` nests (an inner commit's events wait for the outermost), `Core.Access` (pure; one system admin, team leads and staff, no manager (AQ-04A §4.0); tasks in `Core.Access.Tasks`, jobs and companies in `Core.Access.Jobs`, leads in `Core.Access.Leads`, each reading the team's `peer_*` level; share links and pipelines in `Core.Access`) + `Core.Access.Grants` + `Core.AccessMatrixTest` + `Core.TaskAccessMatrixTest` + `Core.JobAccessMatrixTest` + `Core.LeadAccessMatrixTest` (every chair × `hidden · view · edit`) + `Core.ShareLinkTest`, `Core.Auth.Guardian` + `Google`, `Core.Storage`, `Core.Mail`, `Core.Clock` (P4b: the dev clock's offset), `Core.Broadcast`, `Core.PubSub`, `Core.RateLimiter`, Oban's supervisor, `Guardian.DB.Sweeper`, `mix aq.bootstrap`, `mix aq.admin` (hands the one system admin on), `Core.ConventionsTest` |
| `notifire` | delivery: `Notifire.Mailer` (Swoosh), `Notifire.Email`, the three P1 workers (invitation, password reset, email change); P8: `Notifire.Delivery` (the sweep over `notification_deliveries`, `FOR UPDATE SKIP LOCKED`, retries, skips) and `Notifire.Workers.DeliveryWorker` (on write by its configured name, every 5 min), `Notifire.Push` (mCart's RFC 8291/8292, `:crypto` + Req) with the dev outbox `Notifire.Push.Outbox`, `Notifire.Email.for_notification/2` (with a meeting's `invite.ics`) |
| `api_shared` | `ApiShared.Routes` (`/auth/*`, `/me/*`, `/media/*`, `/notifications/*`), the `Auth`, `Me`, `Media`, `Notification` and `Info` controllers, `CustomersJSON` (the customer/profile/channel/document shapes both apps render), `TasksJSON` (the board's shapes of AQ-02 §7.6, the portal's as their own functions), `JobsJSON` (the pool's shapes of AQ-03 §7.1), `LeadsJSON` (AQ-04A §8.3's shapes, staff and customer; P4b: AQ-04B §8.4's note, label, saved view, Tracker row, preview, History page, bulk answer), `FallbackController` (+ `describe/1`, a refusal's code and words for the bulk answer) + `ErrorJSON`, `ExtensionJSON` (AQ-05 §11.3's shapes), `ConversationsJSON` (AQ-06 §11.6's: contact, match, message, conversation, triage item, meeting and the answers), `ApprovalsJSON` (AQ-07 §11.4's: approval row, approval, version, slot, comment, policy row, count, page), the plugs (`AuthPipeline`, `MaybeAuthPipeline`, `Scope`, `TokenApp`); `Routes.extension_routes/1`, the extension's narrower set |
| `api_team` / `api_client` / `api_ext` | one router each, mounted at `/team`, `/client`, `/ext`; each serves `/v1/…`. `api_team` holds the console controllers (org, teams, invitations, people, customers, profiles, channels, documents, skills; P2: board, task, task part, task comment, stage; P3: job, company; P3b: share link; P4a: lead, pipeline; no admins routes; P4b: lead note, label, tracker, saved view, retention, and the dev clock under `dev_routes`; P5: device, extension; P6: contact, conversation (messages, `.eml`, triage, classify), meeting; P7: approval, with a customer's approval policies); `api_ext` the extension's, on device tokens (`ApiExt.Plugs.Device`; session, context, config, job, lead, health; P6: conversation capture); `api_client` the portal's (P2: board, task; no job route in P3; P4a: lead — My applications, *I applied*, suggestions; P4b: the lead page gains its shared tasks; P6: meetings and their ICS, the lead's conversations; P7: approvals — the customer's, deciding, comments), behind `ApiClient.Plugs.CustomerScope` |
| `api` | `Api.Endpoint` (4100), `Api.Router` (forwards the three prefixes, root `GET /info`), `Api.UserSocket` with `Api.UserChannel`, `Api.TeamChannel`, `Api.CustomerChannel`, `Api.LeadChannel` (P4b), the dev clock at `/dev/…` under `dev_routes`, `Api.Telemetry`; P3b: `mix aq.world` (dev only: the P3 cast, tasks and jobs rebuilt through the API as each person from `priv/world/p3-snapshot.json`; `Api.World.*`; P4a: the one system admin (Super Admin, `super-admin@example.com`, since 2026-11-12; Dawud before), both pipelines ensured; P4b: `Api.World.Leads`, P4a's run leads from `priv/world/p4a-snapshot.json`; P5: `Api.World.Extension`, three channels; P6: `Api.World.Conversations`, Mei Chen and Omar Haddad) |

An API app depends on `api_shared` and `core`, never on `api`. `data` never
names a `core` module. The compiler enforces the direction; `Core.ConventionsTest`
enforces the rest. `api_team` also depends on `notifire` (P8), for the dev
routes alone: `POST /dev/sweeps` runs the delivery sweep and `/dev/push/json`
reads the push outbox. `core` never names a `notifire` module.

## Non-negotiables, as implemented

- **Every dependency goes in `apps/utils/mix.exs`.** Every other app carries
  `in_umbrella` deps and nothing else.
- **Every context function takes a `%Data.Scope{}` first.** There are no
  unscoped queries. The struct lives in `data` because `data` cannot name `core`.
  The portal's scope is **pinned** (`Data.Scope.pin_to_customer/1`): no
  portal route takes a customer id, and the same `Core.Customers.*` verbs
  serve both apps — `Core.Access` decides, not a second code path.
- **A customer row carries `team_ids`** (virtual, filled by `Data.Customers`)
  because `Core.Access` decides visibility from it; profiles, channels and
  documents are read with their customer for the same reason.
- **Where a foreign key cannot sit in its own `create`, it is a link table**,
  never an `ALTER`: `person_photos`, `document_media`, `profile_default_documents`.
- **Errors are `{error: {code, message, details}}`**, through
  `ApiShared.FallbackController` and nowhere else. Never `{success: false}`.
  A new `{:error, _}` shape gets its clause in the same change; an unmapped one
  is a 500. `CONVENTIONS.md` §7 lists every code, and PLAN §15.5's as reserved.
- **Verbs are endpoints**, not status patches: `POST /leads/:id/move`, never
  `PATCH {state: …}`. One verb is one transaction.
- **Broadcast after commit, ids only, through the endpoint**
  (`Core.Broadcast.after_commit/2`; the endpoint is injected as
  `config :core, :endpoint`). Never `Phoenix.PubSub` by hand.
- **`core` and `notifire` are siblings.** The notifications table is the
  seam; a worker is named to `core` in config, never in code.
- **One `create table` per migration, no `alter table`, no backfills.**
  Pre-production, a column is added by editing the create migration and
  resetting — both `mix ecto.reset` and `MIX_ENV=test mix ecto.reset`.
- **`_at` is a timestamp; `_on` is a date.** An `Ecto.Enum` field has a
  `CHECK` named `<field>_known`.
- **The domain strings are shared with the frontend**, in `Data.Vocabulary`.
  `mix aq.vocabulary` exports them; the test fails when the file is stale.
  Change both repos or neither.
- **Rules take `now` as an argument** (`Core.Clock.now/0` at the edge),
  never `DateTime.utc_now/0` inside a rule. Every job is idempotent.
- **CORS is an allowlist, never `*`**, and `CORSPlug` sits before the router.
  Production refuses to boot without `CORS_ORIGINS`, `DATABASE_URL`,
  `SECRET_KEY_BASE` and `GUARDIAN_SECRET_KEY`.
- **Tests sit beside their source** — `foo.ex` / `foo.test.exs`. A file named
  `*_test.exs` runs nothing and reports success; `Core.ConventionsTest` fails on
  any. `test/support` holds the cases only.

## Running it

```bash
mix setup            # deps, create, migrate, seeds
mix phx.server       # localhost:4100
curl localhost:4100/info
curl localhost:4100/team/v1/info
```

`mix ecto.reset` drops and rebuilds with every seed; `mix ecto.reset.clean`
leaves what a deployment's database looks like before anyone arrives.
**The standard test users** (all on `password123`, Team 1–3, 21 jobs; `Core.Standard`, `mix aq.seed_standard`, also the end of `mix aq.world`) and the world's cast: [`docs/TEST-ACCOUNTS.md`](./docs/TEST-ACCOUNTS.md).

## Before you finish

```bash
mix precommit
```

Compile without warnings, formatted, `credo --strict` clean, every test green.
Fix everything it reports. If you started `mix phx.server` to check something,
stop it.
