defmodule Utils.JobKeyTest do
  @moduledoc """
  AQ-03 §6.2, every vector a test of its own, then the rules' edges and the
  similar-title rule of §6.3.
  """

  use ExUnit.Case, async: true

  alias Utils.JobKey

  doctest JobKey

  @vectors [
    {"https://careers.bambooinvest.co.uk/jobs/111", "careers.bambooinvest.co.uk/jobs/111",
     :company_site},
    {"https://www.careers.bambooinvest.co.uk/jobs/111/?utm_source=linkedin&utm_medium=social",
     "careers.bambooinvest.co.uk/jobs/111", :company_site},
    {"https://careers.bambooinvest.co.uk/jobs/222", "careers.bambooinvest.co.uk/jobs/222",
     :company_site},
    {"https://www.linkedin.com/jobs/view/4012233871", "linkedin:4012233871", :linkedin},
    {"https://www.linkedin.com/jobs/search/?currentJobId=4012233871&keywords=node",
     "linkedin:4012233871", :linkedin},
    {"https://www.linkedin.com/jobs/view/senior-node-js-engineer-at-fennec-4012233871/?trk=x",
     "linkedin:4012233871", :linkedin},
    {"https://job-boards.greenhouse.io/tailscale/jobs/4612031005",
     "greenhouse:tailscale/4612031005", :greenhouse},
    {"https://boards.greenhouse.io/tailscale/jobs/4612031005?gh_src=abc",
     "greenhouse:tailscale/4612031005", :greenhouse},
    {"https://jobs.lever.co/corvidsecurity/3e8b11d2/apply?lever-origin=applied",
     "lever:corvidsecurity/3e8b11d2", :lever},
    {"https://jobs.ashbyhq.com/ploverlabs/2b6f0c1e?utm_source=x", "ashby:ploverlabs/2b6f0c1e",
     :ashby},
    {"https://apply.workable.com/tuxcare/j/77F0B1/", "workable:tuxcare/77F0B1", :workable},
    {"https://www.upwork.com/jobs/~01a2b3c4d5e6f7a8b9", "upwork:~01a2b3c4d5e6f7a8b9", :upwork},
    {"https://www.upwork.com/freelance-jobs/apply/Go-developer_~01A2B3C4D5E6F7A8B9/",
     "upwork:~01a2b3c4d5e6f7a8b9", :upwork},
    # AQ-05: Upwork's job-details slide-overs, the id after `/details/`.
    {"https://www.upwork.com/nx/search/jobs/details/~01A2B3C4D5E6F7A8B9?pageTitle=Job%20Details",
     "upwork:~01a2b3c4d5e6f7a8b9", :upwork},
    {"https://www.upwork.com/nx/find-work/best-matches/details/~01a2b3c4d5e6f7a8b9",
     "upwork:~01a2b3c4d5e6f7a8b9", :upwork},
    {"https://uk.indeed.com/viewjob?jk=4f3c2b1a0d9e8f7a&from=serp", "indeed:4f3c2b1a0d9e8f7a",
     :indeed},
    {"https://www.indeed.com/jobs?q=golang&vjk=4f3c2b1a0d9e8f7a", "indeed:4f3c2b1a0d9e8f7a",
     :indeed},
    {"https://www.workatastartup.com/jobs/65432", "yc:65432", :yc_waas},
    {"https://www.ycombinator.com/companies/y-combinator/jobs/cpEymTr-product-engineer-new-products",
     "yc:cpEymTr", :yc_waas},
    {"https://wellfound.com/jobs/2987654-senior-elixir-engineer", "wellfound:2987654",
     :wellfound},
    {"careers.example.com/jobs/7#apply", "careers.example.com/jobs/7", :company_site}
  ]

  describe "§6.2's vectors" do
    for {link, key, source} <- @vectors do
      test "#{link} → #{key}" do
        assert {:ok, %{key: unquote(key), source: unquote(source)}} =
                 JobKey.parse(unquote(link))
      end
    end

    test "https://www.linkedin.com/in/someone → :not_a_job" do
      assert JobKey.parse("https://www.linkedin.com/in/someone") == {:error, :not_a_job}
    end

    for link <- ["not a link", "ftp://x.com/a", "https://localhost/x"] do
      test "#{link} → :not_a_link" do
        assert JobKey.parse(unquote(link)) == {:error, :not_a_link}
      end
    end
  end

  describe "beyond the vectors" do
    test "the platform's own id is kept beside the key" do
      assert {:ok, %{source_job_id: "4612031005"}} =
               JobKey.parse("https://boards.greenhouse.io/tailscale/jobs/4612031005")

      assert {:ok, %{source_job_id: "~01a2b3c4d5e6f7a8b9"}} =
               JobKey.parse("https://www.upwork.com/jobs/~01A2B3C4D5E6F7A8B9")

      assert {:ok, %{source_job_id: nil}} = JobKey.parse("https://careers.example.com/jobs/7")
    end

    test "Greenhouse's embed form names the board and the token" do
      assert {:ok, %{key: "greenhouse:tailscale/4612031005"}} =
               JobKey.parse(
                 "https://boards.greenhouse.io/embed/job_app?for=Tailscale&token=4612031005"
               )
    end

    test "Ashby drops /application; board segments are lowercased, ids keep their case" do
      assert {:ok, %{key: "ashby:ploverlabs/2b6F0c1e"}} =
               JobKey.parse("https://jobs.ashbyhq.com/PloverLabs/2b6F0c1e/application")
    end

    test "Upwork's /nx/ job pages carry the id too" do
      assert {:ok, %{key: "upwork:~01abc"}} =
               JobKey.parse("https://www.upwork.com/nx/search/jobs/details/job/~01ABC")
    end

    test "a known board's page without a job id is not a job" do
      for link <- [
            "https://www.upwork.com/nx/search/jobs/?q=golang",
            "https://www.upwork.com/nx/find-work/best-matches/details/",
            "https://www.upwork.com/nx/search/jobs/details/abc",
            "https://uk.indeed.com/jobs?q=golang",
            "https://www.linkedin.com/jobs/search/?keywords=node",
            "https://boards.greenhouse.io/tailscale",
            "https://jobs.lever.co/corvidsecurity",
            "https://wellfound.com/company/acme",
            "https://www.ycombinator.com/companies/y-combinator"
          ] do
        assert JobKey.parse(link) == {:error, :not_a_job}, link
      end
    end

    test "a company site's key keeps the rest of the query, sorted, and ignores the scheme" do
      assert {:ok, %{key: "jobs.acme.io/openings?id=7&team=core"}} =
               JobKey.parse("http://jobs.acme.io/openings/?team=core&ref=x&id=7&fbclid=y")
    end

    test "anything but a string is not a link" do
      assert JobKey.parse(nil) == {:error, :not_a_link}
      assert JobKey.parse("   ") == {:error, :not_a_link}
      assert JobKey.parse("mailto:jobs@acme.io") == {:error, :not_a_link}
    end
  end

  describe "similar_title?/2 (§6.3)" do
    test "60% of the longer title's words, shared" do
      assert JobKey.similar_title?("Senior Backend Engineer", "Backend Engineer")
      assert JobKey.similar_title?("Backend Developer", "backend-developer")
      refute JobKey.similar_title?("Senior Backend Engineer II", "Backend Engineer")
      refute JobKey.similar_title?("", "")
      refute JobKey.similar_title?(nil, "Backend")
    end
  end
end
