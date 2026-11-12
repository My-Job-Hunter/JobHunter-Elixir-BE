defmodule Mix.Tasks.Aq.Bootstrap do
  @shortdoc "Creates the organisation and invites its first admin"

  @moduledoc """
  The front door's first key (AQ-01 §3). Nobody signs up on their own, so the
  first admin's invitation comes from here:

      mix aq.bootstrap --org "Regbits BD" --admin super-admin@example.com --name "Super Admin"

  Creates the organisation with its default settings and an **admin
  invitation** for the email, then prints the accept link. In dev the mail
  also lands in the local mailbox at `localhost:4100/dev/mailbox`.

  **Idempotent**: run twice, it reports the organisation exists and re-issues
  the invitation if none is open. `mix ecto.reset.clean` + `aq.bootstrap` is
  "a deployment before anyone arrives" (PLAN §17).

  It lives in `core`, not `data` with the seed tasks, because it makes the
  organisation through `Core.Organisation.bootstrap/2` — the same code and
  audit rows the front door uses — and `data` cannot name `core`.
  """

  use Mix.Task

  alias Core.Organisation
  alias Core.Organisation.Invitations

  @requirements ["app.start"]

  @impl Mix.Task
  def run(args) do
    {opts, _rest} =
      OptionParser.parse!(args, strict: [org: :string, admin: :string, name: :string])

    org = required(opts, :org, "--org \"Regbits BD\"")
    admin = required(opts, :admin, "--admin super-admin@example.com")
    name = Keyword.get(opts, :name) || hd(String.split(admin, "@"))

    result =
      Data.Seeds.quietly(fn ->
        Organisation.bootstrap(
          %{org_name: org, admin_email: admin, admin_name: name},
          Core.Clock.now()
        )
      end)

    case result do
      {:ok, result} ->
        report(result)

      {:error, :admin_exists} ->
        Mix.raise(
          "The organisation already has its system admin. Hand the role on with mix aq.admin --to <email>."
        )

      {:error, %Ecto.Changeset{} = changeset} ->
        Mix.raise("Could not bootstrap: #{inspect(changeset.errors)}")

      {:error, reason} ->
        Mix.raise("Could not bootstrap: #{inspect(reason)}")
    end
  end

  defp required(opts, key, example) do
    case Keyword.get(opts, key) do
      value when is_binary(value) and value != "" -> value
      _missing -> Mix.raise("mix aq.bootstrap needs #{example}")
    end
  end

  defp report(%{organisation: organisation, invitation: invitation} = result) do
    shell = Mix.shell()

    if result.organisation_created?,
      do: shell.info("Created the organisation #{organisation.name} (#{organisation.slug})."),
      else:
        shell.info("The organisation #{organisation.name} (#{organisation.slug}) already exists.")

    case result.status do
      :issued ->
        shell.info("Invited #{invitation.email} as an admin.")

      :reissued ->
        shell.info("Re-issued the lapsed admin invitation for #{invitation.email}.")

      :open ->
        shell.info(
          "An admin invitation for #{invitation.email} is already open; mailed it again."
        )
    end

    shell.info("Accept link: #{Invitations.accept_url(invitation)}")
    shell.info("Expires: #{DateTime.to_iso8601(invitation.expires_at)}")
  end
end
