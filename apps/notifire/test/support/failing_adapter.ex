defmodule Notifire.FailingAdapter do
  @moduledoc """
  A mail adapter that refuses every message, as a provider does when its
  key is wrong or the mailbox is full: what the sweep's failure path is
  tested against (`Notifire.Delivery.run(now, mailer: [adapter: …])`).
  """

  use Swoosh.Adapter

  @impl Swoosh.Adapter
  def deliver(_email, _config), do: {:error, "mailbox unavailable"}
end
