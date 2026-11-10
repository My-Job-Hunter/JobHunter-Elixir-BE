defmodule Data.Seeds.Skills do
  @moduledoc """
  The skills vocabulary (JH-01 §8, QP1-4): about 120 skills in nine
  categories — languages, frameworks, data, cloud, mobile, design, product,
  QA, management — loaded into **every organisation**, idempotent by slug.

  Skills belong to an organisation (`skills.organisation_id`), and the
  organisation comes from `mix jh.bootstrap`, not the seed. So the seed
  loads into whatever organisations exist (none on a clean database: it
  reports 0 and does no harm), and the bootstrap loads it again for the
  organisation it makes. Either way the slugs are what keep "Node" and
  "Node.js" from both standing.
  """

  import Ecto.Query, warn: false

  alias Data.Organisations.Organisation
  alias Data.Repo
  alias Data.Skills

  @skills %{
    "languages" =>
      ~w(Go Elixir Erlang Python JavaScript TypeScript Java Kotlin Scala Rust) ++
        ["C", "C++", "C#", "Ruby", "PHP", "Swift", "Dart", "SQL", "Bash", "Haskell"],
    "frameworks" =>
      ["Phoenix", "Phoenix LiveView", "Rails", "Django", "FastAPI", "Flask", "Spring Boot"] ++
        ["Node.js", "Express", "NestJS", "React", "Next.js", "Vue", "Nuxt", "Angular", "Svelte"] ++
        ["Laravel", ".NET", "GraphQL", "gRPC", "REST API design", "Tailwind CSS"],
    "data" =>
      ["PostgreSQL", "MySQL", "SQLite", "MongoDB", "Redis", "Elasticsearch", "Kafka", "RabbitMQ"] ++
        ["Spark", "Airflow", "dbt", "Snowflake", "BigQuery", "Pandas", "NumPy", "scikit-learn"] ++
        ["PyTorch", "TensorFlow", "LLM fine-tuning", "Prompt engineering", "Data modelling"],
    "cloud" =>
      ["AWS", "GCP", "Azure", "Docker", "Kubernetes", "Terraform", "Ansible", "Linux"] ++
        ["CI/CD", "GitHub Actions", "Nginx", "Serverless", "Observability", "Fly.io", "Vercel"],
    "mobile" => [
      "iOS",
      "Android",
      "React Native",
      "Flutter",
      "SwiftUI",
      "Jetpack Compose",
      "Expo"
    ],
    "design" =>
      ["Figma", "UI design", "UX research", "Design systems", "Prototyping", "Accessibility"] ++
        ["Motion design", "Illustration", "Brand design", "Webflow"],
    "product" =>
      ["Product management", "Roadmapping", "User interviews", "Analytics", "A/B testing"] ++
        ["Growth", "Technical writing", "SEO", "Pricing", "Go-to-market"],
    "qa" =>
      ["Manual QA", "Test automation", "Playwright", "Cypress", "Selenium", "Load testing"] ++
        ["API testing", "Security testing", "Accessibility testing"],
    "management" =>
      ["Engineering management", "Agile", "Scrum", "Kanban", "OKRs", "Hiring", "Mentoring"] ++
        [
          "Stakeholder management",
          "Project management",
          "Delivery management",
          "Client communication"
        ]
  }

  @doc "The vocabulary as `{category, name}` pairs, in seed order."
  @spec all() :: [{String.t(), String.t()}]
  def all do
    for {category, names} <- Enum.sort(@skills), name <- names, do: {category, name}
  end

  @doc "Loads the vocabulary into every organisation. Answers `%{inserted, kept}`."
  @spec load(keyword()) :: %{inserted: non_neg_integer(), kept: non_neg_integer()}
  def load(_opts \\ []) do
    from(o in Organisation, select: o.id)
    |> Repo.all()
    |> Enum.map(&load_for/1)
    |> Enum.reduce(%{inserted: 0, kept: 0}, fn counts, acc ->
      Map.merge(acc, counts, fn _key, a, b -> a + b end)
    end)
  end

  @doc "Loads the vocabulary into one organisation (the bootstrap's, as it is made)."
  @spec load_for(binary()) :: %{inserted: non_neg_integer(), kept: non_neg_integer()}
  def load_for(organisation_id) do
    Enum.reduce(all(), %{inserted: 0, kept: 0}, fn {category, name}, acc ->
      {:ok, outcome} =
        Skills.upsert(%{organisation_id: organisation_id, name: name, category: category})

      Map.update!(acc, outcome, &(&1 + 1))
    end)
  end
end
