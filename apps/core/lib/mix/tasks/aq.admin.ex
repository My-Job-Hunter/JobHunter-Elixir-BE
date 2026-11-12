defmodule Mix.Tasks.Aq.Admin do
  @shortdoc "Hands the organisation's one system admin role to an existing account"

  @moduledoc """
  The one system admin (AQ-04A §4.0, QP4a-21) is never granted or revoked
  from the app: `org_admins` holds one row per organisation, and this hands
  it on.

      mix aq.admin --to hira@example.com

  The account must exist and be staff (not a customer's sign-in); the
  previous holder keeps whatever team memberships they have, and stops
  being the system admin. The change is an audit row (`admin_handed`, via
  `system`). It refuses an unknown email, and an organisation whose
  bootstrap invitation nobody has accepted yet.

  It lives in `core` because it goes through `Core.Organisation.hand_admin/3`,
  the same audited write a route would use, and `data` cannot name `core`.
  """

  use Mix.Task

  alias Core.Organisation
  alias Data.Organisations
  alias Data.Scope

  @requirements ["app.start"]

  @impl Mix.Task
  def run(args) do
    {opts, _rest} = OptionParser.parse!(args, strict: [to: :string])

    email =
      case Keyword.get(opts, :to) do
        value when is_binary(value) and value != "" -> value
        _missing -> Mix.raise("mix aq.admin needs --to <email>")
      end

    organisation =
      Organisations.the_one() || Mix.raise("There is no organisation yet: run mix aq.bootstrap")

    organisation
    |> Scope.system()
    |> Organisation.hand_admin(email, Core.Clock.now())
    |> report(email)
  end

  defp report(result, email) do
    case result do
      {:ok, admin} ->
        Mix.shell().info("#{admin.user.person.display_name} (#{email}) is the system admin now.")

      {:error, :not_found} ->
        Mix.raise("No account has the email #{email}. Invite them first.")

      {:error, :customer} ->
        Mix.raise("#{email} signs in as a customer; the system admin is staff.")

      {:error, :no_admin} ->
        Mix.raise("Nobody has accepted the bootstrap's admin invitation yet.")

      {:error, reason} ->
        Mix.raise("Could not hand the role on: #{inspect(reason)}")
    end
  end
end
