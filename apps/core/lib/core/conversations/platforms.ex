defmodule Core.Conversations.Platforms do
  @moduledoc """
  What a forwarded mail's sender and subject say (AQ-09 §7 rules 4 and 5,
  QP9-9, QP9-10), **pure**.

  - **A platform's notice** is recognised by its sender: a domain whose
    name (any label but the last) is a job board's or an ATS's —
    LinkedIn, Indeed, Upwork, Wellfound, Greenhouse, Lever, Ashby,
    Workable (`indeed.com`, `match.indeed.com`, `greenhouse-mail.io`,
    `hire.lever.co`, and the run's made-up `indeed.example`). Its company
    and job title are read from the **subject**, whose shapes are regular
    ("Your application was sent to Corvid Security · Senior Golang
    Engineer", "Indeed Application: Senior Golang Engineer", "Thank you
    for applying to Corvid Security"); bodies are not.
  - **The sender's domain** names a company unless it is free mail
    (gmail, outlook, yahoo, icloud, proton…) or a platform's.
  """

  @platforms %{
    "linkedin" => :linkedin,
    "indeed" => :indeed,
    "indeedemail" => :indeed,
    "upwork" => :upwork,
    "wellfound" => :wellfound,
    "angellist" => :wellfound,
    "greenhouse" => :greenhouse,
    "greenhouse-mail" => :greenhouse,
    "lever" => :lever,
    "ashbyhq" => :ashby,
    "workable" => :workable,
    "workablemail" => :workable
  }

  @free ~w(gmail.com googlemail.com outlook.com hotmail.com live.com msn.com yahoo.com ymail.com
           rocketmail.com icloud.com me.com mac.com proton.me protonmail.com pm.me aol.com gmx.com
           gmx.net mail.com zoho.com yandex.com yandex.ru hey.com fastmail.com tutanota.com
           hotmail.co.uk yahoo.co.uk outlook.co.uk)

  @separator ~S"\s+(?:·|•|-|–|—|\||for|:)\s+"

  @doc ~S"""
  The domain of an address, lowercased; `nil` without one.

      iex> Core.Conversations.Platforms.domain("Omar <omar.haddad@Corvid.example>")
      "corvid.example"
      iex> Core.Conversations.Platforms.domain(nil)
      nil
  """
  @spec domain(String.t() | nil) :: String.t() | nil
  def domain(address) when is_binary(address) do
    case Regex.run(~r/@([a-z0-9.-]+\.[a-z0-9-]+)/i, address, capture: :all_but_first) do
      [domain] -> String.downcase(domain)
      nil -> nil
    end
  end

  def domain(_address), do: nil

  @doc ~S"""
  The platform an address belongs to, or `nil`.

      iex> Core.Conversations.Platforms.platform("indeedapply@indeed.example")
      :indeed
      iex> Core.Conversations.Platforms.platform("no-reply@us.greenhouse-mail.io")
      :greenhouse
      iex> Core.Conversations.Platforms.platform("jobs-noreply@linkedin.com")
      :linkedin
      iex> Core.Conversations.Platforms.platform("omar.haddad@corvid.example")
      nil
  """
  @spec platform(String.t() | nil) :: atom() | nil
  def platform(address) do
    case domain(address) do
      nil ->
        nil

      domain ->
        domain
        |> String.split(".")
        |> Enum.drop(-1)
        |> Enum.find_value(&Map.get(@platforms, &1))
    end
  end

  @doc ~S"""
  Whether a domain is free mail: a person's, never a company's.

      iex> Core.Conversations.Platforms.free_mail?("gmail.com")
      true
      iex> Core.Conversations.Platforms.free_mail?("corvid.example")
      false
  """
  @spec free_mail?(String.t() | nil) :: boolean()
  def free_mail?(domain) when is_binary(domain), do: String.downcase(domain) in @free
  def free_mail?(_domain), do: false

  @doc ~S"""
  The domain a sender's company is at (rule 4): the address's, unless it
  is free mail or a platform's.

      iex> Core.Conversations.Platforms.company_domain("omar@corvid.example")
      "corvid.example"
      iex> Core.Conversations.Platforms.company_domain("someone@gmail.com")
      nil
      iex> Core.Conversations.Platforms.company_domain("indeedapply@indeed.example")
      nil
  """
  @spec company_domain(String.t() | nil) :: String.t() | nil
  def company_domain(address) do
    domain = domain(address)
    if domain && not free_mail?(domain) && is_nil(platform(address)), do: domain
  end

  @doc ~S"""
  A notice's company and job title, from its subject (rule 5): `%{company,
  title}` with either `nil` when the subject doesn't say, or `nil` when
  the subject is no notice's shape.

      iex> Core.Conversations.Platforms.notice("Your application was sent to Corvid Security · Senior Golang Engineer")
      %{company: "Corvid Security", title: "Senior Golang Engineer"}
      iex> Core.Conversations.Platforms.notice("Tanweer, your application was sent to Corvid Security")
      %{company: "Corvid Security", title: nil}
      iex> Core.Conversations.Platforms.notice("Indeed Application: Senior Golang Engineer")
      %{company: nil, title: "Senior Golang Engineer"}
      iex> Core.Conversations.Platforms.notice("Thank you for applying to Corvid Security!")
      %{company: "Corvid Security", title: nil}
      iex> Core.Conversations.Platforms.notice("Thanks for applying for the Senior Golang Engineer role at Corvid Security")
      %{company: "Corvid Security", title: "Senior Golang Engineer"}
      iex> Core.Conversations.Platforms.notice("Application received: Senior Golang Engineer at Corvid Security")
      %{company: "Corvid Security", title: "Senior Golang Engineer"}
      iex> Core.Conversations.Platforms.notice("Fwd: Your application to Senior Golang Engineer at Corvid Security")
      %{company: "Corvid Security", title: "Senior Golang Engineer"}
      iex> Core.Conversations.Platforms.notice("Lunch on Friday?")
      nil
  """
  @spec notice(String.t() | nil) :: %{company: String.t() | nil, title: String.t() | nil} | nil
  def notice(subject) when is_binary(subject) do
    subject = Regex.replace(~r/^\s*((re|fw|fwd)\s*:\s*)+/i, subject, "") |> String.trim()

    Enum.find_value(shapes(), fn {pattern, read} ->
      case Regex.named_captures(pattern, subject) do
        nil -> nil
        captures -> read.(captures)
      end
    end)
  end

  def notice(_subject), do: nil

  defp shapes do
    [
      {~r/^(?:.*?,\s*)?(?:your )?application (?:was |has been )?(?:sent|submitted) to (?<company>.+?)(?:#{@separator}(?<title>.+))?$/iu,
       &both(&1["company"], &1["title"])},
      {~r/^indeed application:\s*(?<title>.+)$/iu, &both(nil, &1["title"])},
      {~r/^(?:your )?application (?:to|for) (?<rest>.+)$/iu, &rest(&1["rest"])},
      {~r/^thank(?:s| you) for (?:applying|your application|your interest)(?: to| at| for| with| in)? (?<rest>.+)$/iu,
       &rest(&1["rest"])},
      {~r/^(?:application received|we(?:'ve| have)? received your application)(?:\s*[:\-–]\s*|\s+for\s+)(?<rest>.+)$/iu,
       &rest(&1["rest"])}
    ]
  end

  # "Senior Golang Engineer at Corvid Security", "the … role at …", or a company alone.
  defp rest(text) do
    text = Regex.replace(~r/^the\s+/i, String.trim(text), "")

    case Regex.run(~r/^(.+?)(?:\s+(?:role|position|job))?\s+(?:at|with)\s+(.+)$/iu, text,
           capture: :all_but_first
         ) do
      [title, company] -> both(company, title)
      nil -> both(text, nil)
    end
  end

  defp both(company, title) do
    case {clean(company), clean(title)} do
      {nil, nil} -> nil
      {company, title} -> %{company: company, title: title}
    end
  end

  defp clean(nil), do: nil

  defp clean(text) do
    case text
         |> String.trim()
         |> String.trim_trailing("!")
         |> String.trim_trailing(".")
         |> String.trim() do
      "" -> nil
      value -> value
    end
  end

  @doc ~S"""
  Whether a lead's company and title fit a notice's (`nil` says nothing):
  names compared without case or punctuation, one the start of the other;
  titles equal so, or similar by P3's rule.

      iex> Core.Conversations.Platforms.fits?(%{company: "Corvid Security", title: "Senior Golang Engineer"}, %{company: "Corvid Security Inc.", title: "Senior Golang Engineer (Remote)"})
      true
      iex> Core.Conversations.Platforms.fits?(%{company: "Corvid Security", title: nil}, %{company: "Juniper Edge", title: "Platform Engineer"})
      false
  """
  @spec fits?(map(), map()) :: boolean()
  def fits?(notice, lead) do
    same_company?(notice.company, lead.company) and same_title?(notice.title, lead.title)
  end

  defp same_company?(nil, _lead), do: true
  defp same_company?(_notice, nil), do: false

  defp same_company?(a, b) do
    {a, b} = {plain(a), plain(b)}
    a != "" and b != "" and (String.starts_with?(a, b) or String.starts_with?(b, a))
  end

  defp same_title?(nil, _lead), do: true
  defp same_title?(_notice, nil), do: false

  defp same_title?(a, b) do
    plain(a) == plain(b) or String.starts_with?(plain(b), plain(a)) or
      Utils.JobKey.similar_title?(a, b)
  end

  defp plain(text), do: text |> String.downcase() |> String.replace(~r/[^a-z0-9]+/u, "")
end
