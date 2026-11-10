defmodule Notifire.Mailer do
  @moduledoc """
  The one mailer. The adapter is config: `Swoosh.Adapters.Local` in dev (an
  in-memory mailbox), `Swoosh.Adapters.Test` in test (`assert_email_sent`);
  P7 picks the provider a release sends through.
  """

  use Swoosh.Mailer, otp_app: :notifire
end
