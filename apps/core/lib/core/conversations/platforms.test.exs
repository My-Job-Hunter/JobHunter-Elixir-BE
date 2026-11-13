defmodule Core.Conversations.PlatformsTest do
  @moduledoc "AQ-09 §7 rules 4 and 5, pure: platforms by sender, notices by subject, free mail."

  use ExUnit.Case, async: true

  alias Core.Conversations.Platforms

  doctest Platforms

  test "every platform QP9-10 names, by its sender" do
    for {address, platform} <- [
          {"jobs-noreply@linkedin.com", :linkedin},
          {"indeedapply@indeed.com", :indeed},
          {"alert@indeedemail.com", :indeed},
          {"donotreply@upwork.com", :upwork},
          {"team@wellfound.com", :wellfound},
          {"no-reply@us.greenhouse-mail.io", :greenhouse},
          {"no-reply@hire.lever.co", :lever},
          {"no-reply@ashbyhq.com", :ashby},
          {"noreply@candidates.workablemail.com", :workable}
        ],
        do: assert(Platforms.platform(address) == platform, address)
  end
end
