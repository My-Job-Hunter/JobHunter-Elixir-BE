# Job Hunter — Backend

The Phoenix API behind Job Hunter: the team console (`/team/v1`), the customer
portal (`/client/v1`) and the Chrome extension (`/ext/v1`), served by one
endpoint on **4100**. See [CLAUDE.md](./CLAUDE.md) for how to work here,
[docs/CONVENTIONS.md](./docs/CONVENTIONS.md) for the rules, and
[`../PLAN.md`](../PLAN.md) for the product.

## Setup

Elixir 1.20 / OTP 29 (`.tool-versions`, asdf) and Postgres on
`localhost:5432` as `postgres` / `postgres` (`JH_DB_PORT` to move it).

```bash
mix setup          # deps, job_hunter_dev, migrations, seeds
mix phx.server     # localhost:4100
```

Then:

```bash
curl localhost:4100/info              # {"name":"job_hunter","version":"0.1.0"}
curl localhost:4100/team/v1/info      # {"app":"team","api":"v1","version":"0.1.0"}
curl localhost:4100/client/v1/info
curl localhost:4100/ext/v1/info
```

An unknown path answers `404` as `{"error": {"code": "not_found", …}}`, the
one error shape every route uses.

## The database

```bash
mix ecto.reset         # drop, create, migrate, every seed
mix ecto.reset.clean   # drop, create, migrate, the production seed only
mix jh.seed_reference  # the reference lists (every environment, test included)
mix jh.prod_seed       # what a deployment holds before anyone arrives
mix jh.seed_demo       # dev-only rows
mix jh.vocabulary      # rewrites apps/data/priv/vocabulary.json from Data.Vocabulary
```

The production seed holds the **skills vocabulary** (about 120 skills in nine
categories, idempotent by slug, `Data.Seeds.Skills`). Skills belong to an
organisation, so on a clean database `jh.prod_seed` loads nothing and
`mix jh.bootstrap` loads them for the organisation it makes; run
`mix jh.prod_seed` again any time to top up. `Data.Seeds` lists the groups.

Pre-production, a table changes by editing its `create` migration and
resetting — both `mix ecto.reset` and `MIX_ENV=test mix ecto.reset`.

## The front door

Nobody signs up on their own: every account begins with an invitation, and
the first admin's comes from a mix task (JH-01 §3):

```bash
mix jh.bootstrap --org "Regbits BD" --admin dawud@example.com --name "Dawud Kalim"
# Created the organisation Regbits BD (regbits-bd).
# Invited dawud@example.com as an admin.
# Accept link: http://localhost:5800/invite/9C-C623
```

Idempotent: run it twice and it reports the organisation exists and re-issues
the invitation if none is open. `mix ecto.reset.clean` + `jh.bootstrap` is
"a deployment before anyone arrives".

Then, with the server running:

```bash
curl localhost:4100/team/v1/auth/invitations/9C-C623
curl -X POST localhost:4100/team/v1/auth/invitations/9C-C623/accept \
  -H 'content-type: application/json' \
  -d '{"name":"Dawud Kalim","password":"correct horse battery"}'
# → {access_token, refresh_token, user, landing}
curl localhost:4100/team/v1/me -H "authorization: Bearer $ACCESS_TOKEN"
```

Google sign-in uses a **dev stand-in** until `GOOGLE_CLIENT_ID` is set:
`POST /auth/google {"id_token": "dev:<email>"}` signs in an account that
already has that address (nobody signs up uninvited).

## The dev mailbox

In dev, mail is not sent: every message lands in Swoosh's in-memory mailbox
at **http://localhost:4100/dev/mailbox** (invitations, reset links, email
changes). Mail goes out through Oban jobs on the `emails` queue, so the
server has to be running for a message to appear.

Uploads are written to `priv/uploads` (`config :core, :storage`); a release
needs `UPLOADS_ROOT` on persistent storage.

## Before you finish

```bash
mix precommit
```

Compiles with warnings as errors, checks formatting, runs `credo --strict` and
the whole suite — the same gates CI runs (`.github/workflows/ci.yml`).

## Deploying

`config/runtime.exs` refuses to boot a release without `DATABASE_URL`,
`SECRET_KEY_BASE`, `GUARDIAN_SECRET_KEY`, `CORS_ORIGINS` and `UPLOADS_ROOT`;
`PORT` defaults to 4100. Optional: `GOOGLE_CLIENT_ID` (real Google sign-in),
`CONSOLE_URL`/`PORTAL_URL` (where the mails' links open),
`MAILER_FROM_EMAIL`. `sample.env` lists them all.
