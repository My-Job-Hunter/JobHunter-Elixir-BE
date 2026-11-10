# Claude Instructions — Job Hunter Backend

The Phoenix API behind Job Hunter: the team console, the customer portal and
the Chrome extension. **The product and the build plan live in
[`../PLAN.md`](../PLAN.md)** — the domain, the phases (§18), the rules that
bind (§20). This file says how to work in *this* repository; it does not
restate the plan.

**State: P1 in progress — P1.0 Identity, P1.1 The organisation, P1.2
Customers and P1.3 Access built** (`../docs/phases/JH-01-ACCOUNTS.md`). The
front door (`mix jh.bootstrap`, invitations of all three kinds), sign-in with
a password or Google (dev stand-in), the tokens and sessions, `/me`, the
three-step upload, the organisation with its settings, admins, teams,
members, team settings, people and the audit log; customers with their
teams, notes, profiles (pitch and facts as two verbs), channels, documents
(one row per version) and the skills vocabulary (`jh.prod_seed`); the portal
(`/client/v1`) pinned to the customer by `ApiClient.Plugs.CustomerScope`.
`Core.Access` holds the whole §5.3 matrix and `Core.AccessMatrixTest` asserts
every cell over the fixture organisation. The run record (P1.4) is next.

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

Everything stays clear of AutoCare (4001, 5720–5729, `auto_care_*`), which may
be running on the same machine.

| What | Where |
|---|---|
| This API | **4100** (`JH_PORT`); 4102 in test, never started |
| The team console (Vite) | 5800 |
| The customer portal (Vite) | 5801 |
| Postgres | localhost:5432 (`JH_DB_PORT`), `postgres` / `postgres` |
| Databases | `job_hunter_dev`, `job_hunter_test` (+ `MIX_TEST_PARTITION`) |

The reference implementation is AutoCare at `../../AutoCare/AutoCare-BE-Elixir`.
**Read-only**: copy from it, never change it.

## The shape

```
utils ← data ← core ← api_shared ← api_team · api_client · api_ext ← api
                 ↑
              notifire   (a sibling of core; neither calls the other)
```

| App | Holds |
|---|---|
| `utils` | **every hex dependency** (`apps/utils/mix.exs`), and pure helpers |
| `data` | `Data.Repo`, `Data.Schema` (UUIDv7, `timestamptz`), `Data.Scope`, `Data.Vocabulary`, `Data.Seeds` (+ `Data.Seeds.Skills`), migrations, the schemas and storage contexts (`Data.Accounts`, `Data.Organisations`, `Data.Teams`, `Data.Invitations`, `Data.Audit`, `Data.Files`, `Data.Customers`, `Data.Profiles`, `Data.Channels`, `Data.Documents`, `Data.Skills`), `Data.Mail.Command`, the `jh.seed_*` mix tasks |
| `core` | the contexts (`Core.Accounts` + `Recovery` + `Device`, `Core.Organisation` + `Teams` + `Invitations`, `Core.Customers` + `Profiles` + `Channels` + `Documents` + `Notes` + `Skills` + `Portal`, `Core.Media` + `SweepWorker`, `Core.Audit` + `Labels`), `Core.Access` (pure) + `Core.Access.Grants` + `Core.AccessMatrixTest`, `Core.Auth.Guardian` + `Google`, `Core.Storage`, `Core.Mail`, `Core.Clock`, `Core.Broadcast`, `Core.PubSub`, `Core.RateLimiter`, Oban's supervisor, `Guardian.DB.Sweeper`, `mix jh.bootstrap`, `Core.ConventionsTest` |
| `notifire` | delivery: `Notifire.Mailer` (Swoosh), `Notifire.Email`, the three P1 workers (invitation, password reset, email change). The sweep and push arrive in P7/P8 |
| `api_shared` | `ApiShared.Routes` (`/auth/*`, `/me/*`, `/media/*`), the `Auth`, `Me`, `Media` and `Info` controllers, `CustomersJSON` (the customer/profile/channel/document shapes both apps render), `FallbackController` + `ErrorJSON`, the plugs (`AuthPipeline`, `MaybeAuthPipeline`, `Scope`) |
| `api_team` / `api_client` / `api_ext` | one router each, mounted at `/team`, `/client`, `/ext`; each serves `/v1/…`. `api_team` holds the console controllers (org, teams, invitations, people, customers, profiles, channels, documents, skills); `api_client` the portal's, behind `ApiClient.Plugs.CustomerScope` |
| `api` | `Api.Endpoint` (4100), `Api.Router` (forwards the three prefixes, root `GET /info`), `Api.UserSocket`, `Api.Telemetry` |

An API app depends on `api_shared` and `core`, never on `api`. `data` never
names a `core` module. The compiler enforces the direction; `Core.ConventionsTest`
enforces the rest.

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
  `mix jh.vocabulary` exports them; the test fails when the file is stale.
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

## Before you finish

```bash
mix precommit
```

Compile without warnings, formatted, `credo --strict` clean, every test green.
Fix everything it reports. If you started `mix phx.server` to check something,
stop it.
