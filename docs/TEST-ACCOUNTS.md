# Test users

Every account a tester can sign in with on a dev database, and how to get
them. The user asked for it on 2026-11-12:

> we should have standard users for testing with standard password ie
> password123 … Please document these users properly in md file in backend
> so we can reference again and again

**Every account below signs in with `password123`.** That works on a dev
server only: `config :core, dev_worst_passwords: true` (dev.exs alone)
skips the worst-list for it. Test and a release keep the whole rule and
refuse `password123`.

| App | Where | Who | Sign-in route |
|---|---|---|---|
| The team console | http://localhost:5800 | the system admin, team leads, staff | `POST /team/v1/auth/login {email, password}` |
| The customer portal | http://localhost:5801 | customers | `POST /client/v1/auth/login {email, password}` |
| The API | http://localhost:4100 | both, by the routes above | |

## The standard set

Made by `Core.Standard` through the front door's own code (the bootstrap
and its accepted invitation, teams, invitations accepted with a name and a
password, customers, the portal invitation, profiles, *New job*), so every
row carries the audit a person would leave. The organisation is
**Regbits BD**; the set is idempotent, found again by email, team name,
profile title and job link.

| Email | Password | Name | Role | Team | Signs in to | What it can do |
|---|---|---|---|---|---|---|
| `super-admin@example.com` | `password123` | Super Admin | system admin | none — every team | console :5800 | **Anything, in any team**: switch to any team; make, rename and archive teams; change roles; invite team leads; Settings › System; the audit log; every customer (one in no team too), job, lead, task and approval. The organisation has exactly one system admin. |
| `team-lead1@example.com` | `password123` | Team Lead 1 | team lead | Team 1 | console :5800 | Runs Team 1: invites its staff; adds customers to it, invites them to the portal, edits their pitch; merges and archives jobs; moves and hands on any of the team's leads; the team's settings, pipelines, labels and approval rules. Not: teams, roles, inviting a lead. |
| `team-lead2@example.com` | `password123` | Team Lead 2 | team lead | Team 2 | console :5800 | As Team Lead 1, for Team 2. |
| `team-lead3@example.com` | `password123` | Team Lead 3 | team lead | Team 3 | console :5800 | As Team Lead 1, for Team 3. |
| `staff1@example.com` | `password123` | Staff 1 | staff (BD) | Team 1 | console :5800 | BD work in Team 1: adds jobs to the pool, makes and works their own leads, tasks, conversations and meetings; edits profile facts (not the pitch); owns Customer 1's profile. Sees teammates' tasks and leads, edits their jobs (the team's default `view · view · edit`). |
| `staff2@example.com` | `password123` | Staff 2 | staff (BD) | Team 2 | console :5800 | As Staff 1, in Team 2; owns Customer 2's profile. |
| `staff3@example.com` | `password123` | Staff 3 | staff (BD) | Team 3 | console :5800 | As Staff 1, in Team 3; owns Customer 3's profile. |
| `customer1@example.com` | `password123` | Customer 1 | customer | served by Team 1 | portal :5801 | Their own portal: profiles, *My applications* and *I applied*, the tasks, meetings and approvals shared with them. Never another customer's rows, never staff notes. |
| `customer2@example.com` | `password123` | Customer 2 | customer | served by Team 2 | portal :5801 | As Customer 1. |
| `customer3@example.com` | `password123` | Customer 3 | customer | served by Team 3 | portal :5801 | As Customer 1. |

A staff account can sign in on `/client`, but every portal route answers
`404 not_a_customer` ("This sign-in is for customers."); a customer signed
in on `/team` holds no staff role, so the console's routes answer
`404 not_found`.

### The teams

| Team | Lead | Staff | Customer | Jobs | Settings |
|---|---|---|---|---|---|
| Team 1 | Team Lead 1 | Staff 1 | Customer 1 | 7, backend | the defaults: `peer_tasks view`, `peer_leads view`, `peer_jobs edit`; the customer sees staff names and conversations, not job suggestions |
| Team 2 | Team Lead 2 | Staff 2 | Customer 2 | 7, frontend | the defaults |
| Team 3 | Team Lead 3 | Staff 3 | Customer 3 | 7, full-stack | the defaults |

Super Admin made the teams and invited each lead; each lead invited their
staff, made their team's customer and profile, and added the team's jobs.

### The customers

All three are **active** ("approved and ready to go"): the portal
invitation was accepted with `password123`, which made them active, and
each has one active profile, owned by their team's staff member, so leads
can be made for it straight away.

| Customer | Email | Team | Status | Portal account | Profile | Owner | Location |
|---|---|---|---|---|---|---|---|
| Customer 1 | `customer1@example.com` | Team 1 | active | accepted | Customer 1 · Backend Engineer (mid-senior, 6 years, full time or contract, remote) | Staff 1 | Lahore, PK |
| Customer 2 | `customer2@example.com` | Team 2 | active | accepted | Customer 2 · Frontend Engineer (mid-senior, 5 years, full time or fixed-price freelance, remote or hybrid) | Staff 2 | Karachi, PK |
| Customer 3 | `customer3@example.com` | Team 3 | active | accepted | Customer 3 · Full-stack Engineer (mid-senior, 7 years, full time, contract or hourly freelance, remote) | Staff 3 | Islamabad, PK |

### The 21 jobs

Three from each of seven boards — one per board in each team's pool —
added by that team's lead through *New job* (`Core.Jobs.create/3`, the verb
behind `POST /team/v1/jobs`). Every company is fictional and every id made
up; each link has its board's real address pattern, so the app detects the
source from it (`Utils.JobKey`). Each company has a `.example` website.
`posted_on` is a few days before the seed ran. Defined in
`apps/core/lib/core/standard/pool.ex`.

| Team | Board | Title | Company | Pay | Workplace | Engagement | Link |
|---|---|---|---|---|---|---|---|
| Team 1 | LinkedIn | Senior Backend Engineer (Elixir) | Ferrowind Logistics | USD 110,000–140,000/year | remote | full time | <https://www.linkedin.com/jobs/view/4120000101/> |
| Team 1 | Indeed | Backend Developer (Node.js / PostgreSQL) | Brindlepath Health | USD 85,000–105,000/year | hybrid (Austin, TX) | full time | <https://www.indeed.com/viewjob?jk=7d3f19a2c4e80101> |
| Team 1 | Upwork | Build a REST API for a fleet-tracking dashboard | Quillmere Freight | USD 35–55/hour | remote | freelance hourly, 1–3 months | <https://www.upwork.com/jobs/~01a7c3e9f2b4d60101> |
| Team 1 | Wellfound | Founding Backend Engineer | Sablecrest Analytics | USD 130,000–160,000/year + 0.25–0.75% options | remote | full time | <https://wellfound.com/jobs/3120101-founding-backend-engineer> |
| Team 1 | YC Work at a Startup | Backend Engineer, Payments | Tallowpay | USD 140,000–170,000/year + 0.1–0.5% options | remote (North America) | full time | <https://www.workatastartup.com/jobs/71101> |
| Team 1 | Greenhouse | Software Engineer, Platform | Glimmerdock | USD 150,000–185,000/year | hybrid (New York, NY) | full time | <https://boards.greenhouse.io/glimmerdock/jobs/6120101> |
| Team 1 | Lever | Senior Go Engineer | Vantafield Systems | EUR 75,000–95,000/year | remote (Europe) | full time | <https://jobs.lever.co/vantafield/2f6b1c8e-4a3d-4e9b-9c1a-7d5e3b2a0101> |
| Team 2 | LinkedIn | Senior Frontend Engineer (React) | Pinecask Media | USD 100,000–130,000/year | remote | full time | <https://www.linkedin.com/jobs/view/4120000201/> |
| Team 2 | Indeed | Front-End Developer (Vue.js) | Mossgrove Retail | USD 80,000–95,000/year | on-site (Chicago, IL) | full time | <https://www.indeed.com/viewjob?jk=a4e81c7b3f290201> |
| Team 2 | Upwork | Vue 3 admin panel for a SaaS billing product | Copperlane Studio | USD 3,500 fixed | remote | freelance fixed, 1–3 months | <https://www.upwork.com/jobs/~01b8d4f0a3c5e70201> |
| Team 2 | Wellfound | Frontend Engineer, Design Systems | Driftmark Design | USD 120,000–150,000/year + 0.1–0.4% options | remote | full time | <https://wellfound.com/jobs/3120201-frontend-engineer-design-systems> |
| Team 2 | YC Work at a Startup | Founding Frontend Engineer | Kitewell Health | USD 150,000–180,000/year + 0.5–1.5% options | hybrid (San Francisco, CA) | full time | <https://www.workatastartup.com/jobs/71201> |
| Team 2 | Greenhouse | Frontend Engineer, Growth | Wrenfold Ledger | USD 135,000–165,000/year | remote (North America) | full time | <https://boards.greenhouse.io/wrenfoldledger/jobs/6120201> |
| Team 2 | Lever | UI Engineer (TypeScript) | Cindermoss Labs | GBP 60,000–75,000/year | remote (Europe) | full time | <https://jobs.lever.co/cindermoss/5a9e2d7c-1b4f-4c8a-8e3d-6f2b1a9c0201> |
| Team 3 | LinkedIn | Full-stack Engineer (Phoenix + Vue) | Saltmarsh Robotics | USD 105,000–135,000/year | remote | full time | <https://www.linkedin.com/jobs/view/4120000301/> |
| Team 3 | Indeed | Full Stack Developer | Hollowbrook Insurance | USD 90,000–110,000/year | hybrid (Denver, CO) | full time | <https://www.indeed.com/viewjob?jk=c9f27e4a1d830301> |
| Team 3 | Upwork | Full-stack developer for a booking MVP (Elixir/Phoenix) | Gildenrow Travel | USD 6,000 fixed | remote | freelance fixed, 1–3 months | <https://www.upwork.com/jobs/~01c2e6a8b4d0f90301> |
| Team 3 | Wellfound | Full-stack Engineer, Early Team | Ravelstone Labs | USD 115,000–145,000/year + 0.2–0.8% options | remote | full time | <https://wellfound.com/jobs/3120301-full-stack-engineer-early-team> |
| Team 3 | YC Work at a Startup | Full-stack Engineer | Nookfield Homes | USD 130,000–160,000/year + 0.25–1% options | remote (North America) | full time | <https://www.workatastartup.com/jobs/71301> |
| Team 3 | Greenhouse | Software Engineer, Full Stack | Quartzhollow Commerce | CAD 120,000–145,000/year | hybrid (Toronto, ON) | full time | <https://boards.greenhouse.io/quartzhollow/jobs/6120301> |
| Team 3 | Lever | Senior Full-stack Engineer | Mirefox Data | USD 70–90/hour | remote | contract, 3–6 months | <https://jobs.lever.co/mirefox/8c3d5f1a-2e7b-4d9c-a1f6-4b8e0d2c0301> |

## How to get them

All three need Postgres on 5432 and leave mCart alone.

**The standard set alone:**

```bash
mix ecto.reset
```

Drops `autoqare_dev`, migrates, runs every seed and, last,
`mix aq.seed_standard`: Regbits BD with the ten accounts, three teams, three
customers and 21 jobs, and nothing else. Then `mix phx.server` and sign in.

**The full world plus the standard set:**

```bash
mix ecto.reset.clean                         # the production seed only, no accounts
mix phx.server                               # in another terminal, on 4100
AQ_CAST_PASSWORD=password123 mix aq.world    # the world over HTTP, then the standard set
```

`mix aq.world` needs an empty database and the server answering. It
rebuilds the world's cast, teams, tasks, jobs, leads and contacts through
the API, then calls the same `Core.Standard.ensure/3` in-process with
`AQ_CAST_PASSWORD`: Team 1–3 and their people sit beside Backend squad and
Frontend squad. Stop the server when you're done.

**Topping up an existing dev database:** `mix aq.seed_standard` (or
`mix ecto.seed`) makes only what is missing; run twice, the second run makes
nothing. It refuses, with how to fix it, when the organisation's system
admin is somebody other than `super-admin@example.com` — an older database
from before 2026-11-12, where Dawud was the admin: reset it as above.

**Tests** get none of this: the suite's database holds the reference seed
only. `Core.StandardTest` builds the set with a strong password, because
the worst-list refuses `password123` there.

## The world's own cast

What `mix aq.world` makes from `apps/api/priv/world/p3-snapshot.json` and
`p4a-snapshot.json`, all on `AQ_CAST_PASSWORD` (`password123` by the rule
above). Organisation **Regbits BD**, teams **Backend squad** and **Frontend
squad**.

**On 2026-11-12 Super Admin replaced Dawud** (`dawud@example.com`, "Dawud
Kalim") as the one system admin: the world bootstraps
`super-admin@example.com`, the snapshots name Super Admin wherever they
named Dawud, and everything Dawud did in the world (the organisation, the
teams, the customers and their profiles, the channels, the leads' team
settings) Super Admin does now. Dawud is no longer in the cast.

| Email | Name | Role | Team | Signs in to |
|---|---|---|---|---|
| `super-admin@example.com` | Super Admin | system admin | none — every team | console :5800 |
| `hira@example.com` | Hira Khan | team lead | Backend squad **and** Frontend squad | console :5800 |
| `bilal@example.com` | Bilal Ahmed | team lead | Backend squad | console :5800 |
| `fiza@example.com` | Fiza Malik | staff | Backend squad **and** Frontend squad | console :5800 |
| `qasim@example.com` | Qasim Raza | staff | Backend squad | console :5800 |
| `muaz@example.com` | Muaz Tariq | staff | Backend squad | console :5800 |
| `tanweer@example.com` | Muhammad Tanweer (customer "Tanweer") | customer, portal account | Backend squad and Frontend squad | portal :5801 |

The world's other customers have **no account** to sign in with:

| Customer | Email | Team | Status | Profiles |
|---|---|---|---|---|
| Tanweer | `tanweer@example.com` | Backend squad, Frontend squad | active, portal account | Golang backend |
| Naveed | `naveed@example.com` | Backend squad | active (paused in P3's run, active again in P4a's) | Elixir backend, Golang |
| Sara | `sara@example.com` | Backend squad | invited; her portal invitation is open | — |
| Imran | `imran@example.com` | Frontend squad | invited; never sent a portal invitation | AI/ML engineer |

Also in the world, not accounts: the contacts **Mei Chen** (recruiter,
Juniper Edge) and **Omar Haddad** (hiring manager, Corvid Security), P6's.

The world's jobs, leads, tasks and share link are P3's and P4a's runs as
recorded in `../docs/runs/`; `mix aq.world` prints their counts when it
finishes.
