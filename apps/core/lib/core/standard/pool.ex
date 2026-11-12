defmodule Core.Standard.Pool do
  @moduledoc """
  The standard set's 21 jobs (`Core.Standard`, `docs/TEST-ACCOUNTS.md`): one
  from each of seven boards — LinkedIn, Indeed, Upwork, Wellfound, YC Work
  at a Startup, Greenhouse and Lever — in each of Team 1, 2 and 3's pools.
  Team 1's are backend roles, Team 2's frontend and Team 3's full-stack, to
  match the profile of the customer each team serves.

  **Every company is fictional and every id made up**; each link follows
  its board's real address pattern, so `Utils.JobKey` detects the source
  the way the app does, and the link's key is how `Core.Standard` finds the
  job again. Pure: data in, the body *New job* sends (`POST /team/v1/jobs`)
  out.
  """

  @jobs [
    # ── Team 1: backend ─────────────────────────────────────────────────────
    %{
      team: 1,
      source: "linkedin",
      url: "https://www.linkedin.com/jobs/view/4120000101/",
      title: "Senior Backend Engineer (Elixir)",
      company: "Ferrowind Logistics",
      seniority: "mid_senior",
      workplace: "remote",
      remote_scope: "global",
      engagement: "full_time",
      comp: {11_000_000, 14_000_000, "USD", "year"},
      apply: "in_platform_easy",
      age: 2,
      description:
        "Ferrowind plans routes for mid-size freight carriers. You'll own the Phoenix " <>
          "services behind dispatch and live tracking.\n\n- 5+ years of backend work, 2+ in " <>
          "Elixir\n- PostgreSQL you can tune, Oban you've run in production\n- Four hours' " <>
          "overlap with US Eastern"
    },
    %{
      team: 1,
      source: "indeed",
      url: "https://www.indeed.com/viewjob?jk=7d3f19a2c4e80101",
      title: "Backend Developer (Node.js / PostgreSQL)",
      company: "Brindlepath Health",
      seniority: "associate",
      workplace: "hybrid",
      onsite: ["Austin, TX"],
      engagement: "full_time",
      comp: {8_500_000, 10_500_000, "USD", "year"},
      apply: "in_platform_easy",
      age: 5,
      description:
        "Brindlepath builds scheduling for outpatient clinics. Join a team of six on the " <>
          "patient-booking API.\n\n- 2+ years with Node.js and TypeScript\n- Comfortable with " <>
          "SQL and migrations\n- Three days a week in our Austin office"
    },
    %{
      team: 1,
      source: "upwork",
      url: "https://www.upwork.com/jobs/~01a7c3e9f2b4d60101",
      title: "Build a REST API for a fleet-tracking dashboard",
      company: "Quillmere Freight",
      seniority: "mid_senior",
      workplace: "remote",
      remote_scope: "global",
      engagement: "freelance_hourly",
      duration: "1_3m",
      comp: {3_500, 5_500, "USD", "hour"},
      apply: "proposal",
      age: 1,
      description:
        "We have a React dashboard and need the API behind it: vehicles, trips and " <>
          "geofence alerts.\n\n- REST with OpenAPI docs\n- PostgreSQL + PostGIS a plus\n- " <>
          "About 25 hours a week for two months"
    },
    %{
      team: 1,
      source: "wellfound",
      url: "https://wellfound.com/jobs/3120101-founding-backend-engineer",
      title: "Founding Backend Engineer",
      company: "Sablecrest Analytics",
      seniority: "mid_senior",
      workplace: "remote",
      remote_scope: "global",
      engagement: "full_time",
      comp: {13_000_000, 16_000_000, "USD", "year"},
      equity: {25, 75, "options"},
      apply: "in_platform_easy",
      age: 4,
      description:
        "Seed-stage analytics for subscription businesses. You'd be engineer number two, " <>
          "owning ingestion and the metrics API.\n\n- Event pipelines at scale\n- Elixir or " <>
          "Go\n- Happy to talk to customers"
    },
    %{
      team: 1,
      source: "yc_waas",
      url: "https://www.workatastartup.com/jobs/71101",
      title: "Backend Engineer, Payments",
      company: "Tallowpay",
      seniority: "mid_senior",
      workplace: "remote",
      remote_scope: "region",
      regions: ["north_america"],
      engagement: "full_time",
      comp: {14_000_000, 17_000_000, "USD", "year"},
      equity: {10, 50, "options"},
      apply: "in_platform_easy",
      age: 3,
      description:
        "Tallowpay runs payouts for gig platforms. Build the ledger and the reconciliation " <>
          "jobs that move money every night.\n\n- Double-entry ledgers or payments experience\n- " <>
          "Strong PostgreSQL\n- North American time zones"
    },
    %{
      team: 1,
      source: "greenhouse",
      url: "https://boards.greenhouse.io/glimmerdock/jobs/6120101",
      title: "Software Engineer, Platform",
      company: "Glimmerdock",
      seniority: "mid_senior",
      workplace: "hybrid",
      onsite: ["New York, NY"],
      engagement: "full_time",
      comp: {15_000_000, 18_500_000, "USD", "year"},
      apply: "external_ats",
      age: 7,
      description:
        "Glimmerdock's platform team keeps 40 services deployable. Own the build pipeline, " <>
          "service templates and on-call tooling.\n\n- Kubernetes and Terraform\n- One backend " <>
          "language in depth\n- Two days a week in Manhattan"
    },
    %{
      team: 1,
      source: "lever",
      url: "https://jobs.lever.co/vantafield/2f6b1c8e-4a3d-4e9b-9c1a-7d5e3b2a0101",
      title: "Senior Go Engineer",
      company: "Vantafield Systems",
      seniority: "mid_senior",
      workplace: "remote",
      remote_scope: "region",
      regions: ["europe"],
      engagement: "full_time",
      comp: {7_500_000, 9_500_000, "EUR", "year"},
      apply: "external_ats",
      age: 9,
      description:
        "Vantafield monitors industrial sensors. Write the Go services that take in a " <>
          "million readings a minute.\n\n- 4+ years of Go\n- Kafka or NATS\n- Within three " <>
          "hours of CET"
    },

    # ── Team 2: frontend ────────────────────────────────────────────────────
    %{
      team: 2,
      source: "linkedin",
      url: "https://www.linkedin.com/jobs/view/4120000201/",
      title: "Senior Frontend Engineer (React)",
      company: "Pinecask Media",
      seniority: "mid_senior",
      workplace: "remote",
      remote_scope: "global",
      engagement: "full_time",
      comp: {10_000_000, 13_000_000, "USD", "year"},
      apply: "in_platform_easy",
      age: 3,
      description:
        "Pinecask makes a video editor that runs in the browser. Lead the timeline and " <>
          "export screens.\n\n- 5+ years of React and TypeScript\n- Canvas or WebGL a plus\n- " <>
          "Care for accessibility"
    },
    %{
      team: 2,
      source: "indeed",
      url: "https://www.indeed.com/viewjob?jk=a4e81c7b3f290201",
      title: "Front-End Developer (Vue.js)",
      company: "Mossgrove Retail",
      seniority: "associate",
      workplace: "on_site",
      onsite: ["Chicago, IL"],
      engagement: "full_time",
      comp: {8_000_000, 9_500_000, "USD", "year"},
      apply: "in_platform_easy",
      age: 6,
      description:
        "Mossgrove runs 80 garden stores. Build the store-pickup and loyalty pages of our " <>
          "web shop.\n\n- 2+ years of Vue 3\n- CSS you're proud of\n- In our Chicago office " <>
          "five days a week"
    },
    %{
      team: 2,
      source: "upwork",
      url: "https://www.upwork.com/jobs/~01b8d4f0a3c5e70201",
      title: "Vue 3 admin panel for a SaaS billing product",
      company: "Copperlane Studio",
      seniority: "mid_senior",
      workplace: "remote",
      remote_scope: "global",
      engagement: "freelance_fixed",
      duration: "1_3m",
      comp: {350_000, 350_000, "USD", "project"},
      apply: "proposal",
      age: 1,
      description:
        "Fixed price. We have the API and Figma; we need the admin panel: customers, " <>
          "invoices, plans and refunds.\n\n- Vue 3, Pinia, Vite\n- Tables with filters and " <>
          "CSV export\n- Six weeks"
    },
    %{
      team: 2,
      source: "wellfound",
      url: "https://wellfound.com/jobs/3120201-frontend-engineer-design-systems",
      title: "Frontend Engineer, Design Systems",
      company: "Driftmark Design",
      seniority: "mid_senior",
      workplace: "remote",
      remote_scope: "global",
      engagement: "full_time",
      comp: {12_000_000, 15_000_000, "USD", "year"},
      equity: {10, 40, "options"},
      apply: "in_platform_easy",
      age: 5,
      description:
        "Driftmark sells a design-system kit to product teams. Build the components and " <>
          "the docs site that shows them off.\n\n- React or Vue, and Storybook\n- Tokens and " <>
          "theming\n- An eye for detail"
    },
    %{
      team: 2,
      source: "yc_waas",
      url: "https://www.workatastartup.com/jobs/71201",
      title: "Founding Frontend Engineer",
      company: "Kitewell Health",
      seniority: "mid_senior",
      workplace: "hybrid",
      onsite: ["San Francisco, CA"],
      engagement: "full_time",
      comp: {15_000_000, 18_000_000, "USD", "year"},
      equity: {50, 150, "options"},
      apply: "in_platform_easy",
      age: 2,
      description:
        "Kitewell helps physiotherapists follow up with patients. Own the web app from " <>
          "the first screen.\n\n- React and TypeScript\n- Product sense\n- Three days a week " <>
          "in San Francisco"
    },
    %{
      team: 2,
      source: "greenhouse",
      url: "https://boards.greenhouse.io/wrenfoldledger/jobs/6120201",
      title: "Frontend Engineer, Growth",
      company: "Wrenfold Ledger",
      seniority: "mid_senior",
      workplace: "remote",
      remote_scope: "region",
      regions: ["north_america"],
      engagement: "full_time",
      comp: {13_500_000, 16_500_000, "USD", "year"},
      apply: "external_ats",
      age: 8,
      description:
        "Wrenfold does bookkeeping for small firms. Run experiments on sign-up and " <>
          "onboarding.\n\n- 3+ years of frontend\n- A/B testing and analytics\n- North " <>
          "American hours"
    },
    %{
      team: 2,
      source: "lever",
      url: "https://jobs.lever.co/cindermoss/5a9e2d7c-1b4f-4c8a-8e3d-6f2b1a9c0201",
      title: "UI Engineer (TypeScript)",
      company: "Cindermoss Labs",
      seniority: "mid_senior",
      workplace: "remote",
      remote_scope: "region",
      regions: ["europe"],
      engagement: "full_time",
      comp: {6_000_000, 7_500_000, "GBP", "year"},
      apply: "external_ats",
      age: 10,
      description:
        "Cindermoss builds lab-notebook software. Make dense scientific screens fast and " <>
          "readable.\n\n- TypeScript, React or Vue\n- Virtualised lists and charts\n- European " <>
          "time zones"
    },

    # ── Team 3: full-stack ──────────────────────────────────────────────────
    %{
      team: 3,
      source: "linkedin",
      url: "https://www.linkedin.com/jobs/view/4120000301/",
      title: "Full-stack Engineer (Phoenix + Vue)",
      company: "Saltmarsh Robotics",
      seniority: "mid_senior",
      workplace: "remote",
      remote_scope: "global",
      engagement: "full_time",
      comp: {10_500_000, 13_500_000, "USD", "year"},
      apply: "in_platform_easy",
      age: 4,
      description:
        "Saltmarsh builds warehouse robots. Build the fleet console operators use all " <>
          "day.\n\n- Phoenix and LiveView or Vue\n- Realtime UIs over websockets\n- Some " <>
          "overlap with US Pacific"
    },
    %{
      team: 3,
      source: "indeed",
      url: "https://www.indeed.com/viewjob?jk=c9f27e4a1d830301",
      title: "Full Stack Developer",
      company: "Hollowbrook Insurance",
      seniority: "associate",
      workplace: "hybrid",
      onsite: ["Denver, CO"],
      engagement: "full_time",
      comp: {9_000_000, 11_000_000, "USD", "year"},
      apply: "in_platform_easy",
      age: 7,
      description:
        "Hollowbrook sells renters' insurance online. Work across the quote flow and the " <>
          "agent portal.\n\n- C# or Node.js on the server\n- React on the client\n- Two days a " <>
          "week in Denver"
    },
    %{
      team: 3,
      source: "upwork",
      url: "https://www.upwork.com/jobs/~01c2e6a8b4d0f90301",
      title: "Full-stack developer for a booking MVP (Elixir/Phoenix)",
      company: "Gildenrow Travel",
      seniority: "mid_senior",
      workplace: "remote",
      remote_scope: "global",
      engagement: "freelance_fixed",
      duration: "1_3m",
      comp: {600_000, 600_000, "USD", "project"},
      apply: "proposal",
      age: 2,
      description:
        "Fixed price. A booking MVP for small tour operators: listings, a calendar, " <>
          "Stripe checkout and an admin.\n\n- Elixir and Phoenix\n- Deployed on Fly.io\n- " <>
          "Eight weeks, weekly demos"
    },
    %{
      team: 3,
      source: "wellfound",
      url: "https://wellfound.com/jobs/3120301-full-stack-engineer-early-team",
      title: "Full-stack Engineer, Early Team",
      company: "Ravelstone Labs",
      seniority: "mid_senior",
      workplace: "remote",
      remote_scope: "global",
      engagement: "full_time",
      comp: {11_500_000, 14_500_000, "USD", "year"},
      equity: {20, 80, "options"},
      apply: "in_platform_easy",
      age: 6,
      description:
        "Ravelstone turns supplier contracts into structured data. Ship features end to " <>
          "end, from the parser to the review screen.\n\n- TypeScript everywhere\n- PostgreSQL" <>
          "\n- Comfortable with ambiguity"
    },
    %{
      team: 3,
      source: "yc_waas",
      url: "https://www.workatastartup.com/jobs/71301",
      title: "Full-stack Engineer",
      company: "Nookfield Homes",
      seniority: "mid_senior",
      workplace: "remote",
      remote_scope: "region",
      regions: ["north_america"],
      engagement: "full_time",
      comp: {13_000_000, 16_000_000, "USD", "year"},
      equity: {25, 100, "options"},
      apply: "in_platform_easy",
      age: 3,
      description:
        "Nookfield manages short-term rentals for owners. Build owner statements, " <>
          "cleaning schedules and the guest app.\n\n- Rails, Phoenix or Django\n- React or " <>
          "Vue\n- North American hours"
    },
    %{
      team: 3,
      source: "greenhouse",
      url: "https://boards.greenhouse.io/quartzhollow/jobs/6120301",
      title: "Software Engineer, Full Stack",
      company: "Quartzhollow Commerce",
      seniority: "mid_senior",
      workplace: "hybrid",
      onsite: ["Toronto, ON"],
      engagement: "full_time",
      comp: {12_000_000, 14_500_000, "CAD", "year"},
      apply: "external_ats",
      age: 11,
      description:
        "Quartzhollow powers checkout for independent shops. Work on the merchant " <>
          "dashboard and its APIs.\n\n- 3+ years full-stack\n- GraphQL\n- Two days a week in " <>
          "Toronto"
    },
    %{
      team: 3,
      source: "lever",
      url: "https://jobs.lever.co/mirefox/8c3d5f1a-2e7b-4d9c-a1f6-4b8e0d2c0301",
      title: "Senior Full-stack Engineer",
      company: "Mirefox Data",
      seniority: "mid_senior",
      workplace: "remote",
      remote_scope: "global",
      engagement: "contract",
      duration: "3_6m",
      comp: {7_000, 9_000, "USD", "hour"},
      apply: "external_ats",
      age: 12,
      description:
        "Six-month contract. Mirefox needs a second engineer on its data-quality product: " <>
          "rules editor, alerts and the API behind them.\n\n- Python or Elixir on the " <>
          "server\n- Vue or React\n- 30–40 hours a week"
    }
  ]

  @doc "Every job, each with its team's number (`team`)."
  @spec all() :: [map()]
  def all, do: @jobs

  @doc "Team `n`'s seven, in board order."
  @spec for_team(pos_integer()) :: [map()]
  def for_team(n), do: Enum.filter(@jobs, &(&1.team == n))

  @doc """
  The body *New job* sends (`POST /team/v1/jobs`) for `job` in `team_id`:
  the link, the sheet's columns, the company by name (found or made, as
  the form does) and `posted_on` the job's `age` in days before `now`'s day.
  """
  @spec params(map(), binary(), DateTime.t()) :: map()
  def params(job, team_id, %DateTime{} = now) do
    {min, max, currency, period} = job.comp
    {equity_min, equity_max, equity_kind} = job[:equity] || {nil, nil, nil}

    %{
      "team_id" => team_id,
      "url" => job.url,
      "title" => job.title,
      "company" => %{"name" => job.company, "website_url" => website(job.company)},
      "description_md" => job.description,
      "seniority" => job.seniority,
      "workplace" => job.workplace,
      "remote_scope" => job[:remote_scope],
      "allowed_regions" => job[:regions],
      "onsite_locations" => job[:onsite],
      "engagement" => job.engagement,
      "duration" => job[:duration],
      "comp_min_minor" => min,
      "comp_max_minor" => max,
      "comp_currency" => currency,
      "comp_period" => period,
      "comp_source" => "employer",
      "equity_min_bp" => equity_min,
      "equity_max_bp" => equity_max,
      "equity_kind" => equity_kind,
      "apply_method" => job.apply,
      "posted_on" => Date.add(DateTime.to_date(now), -job.age)
    }
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  # A fictional company's site, on the reserved `.example` domain.
  defp website(company) do
    slug = company |> String.downcase() |> String.split() |> hd()
    "https://#{slug}.example"
  end
end
