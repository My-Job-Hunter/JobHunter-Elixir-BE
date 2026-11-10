defmodule Core.RateLimiter do
  @moduledoc """
  The ETS bucket store behind `Core.Plugs.RateLimit`.

  **Per node, and honest about it.** ETS is process-local, so two nodes each
  allow the configured limit. For one node that is exactly right; for two, the
  answer is Hammer's Redis backend rather than halving the number and hoping.
  """

  use Hammer, backend: :ets
end
