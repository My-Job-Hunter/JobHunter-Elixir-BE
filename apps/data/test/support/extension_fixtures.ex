defmodule Data.Fixtures.Extension do
  @moduledoc """
  The extension's fixtures (AQ-05 §13), reached through `Data.Fixtures`
  (`device_fixture/2`, `signal_fixture/2`, `config_fixture/2`). Like the
  rest, they take a scope (or what a scope reaches) and write through
  `Data.*`. A device's tokens are Guardian's, which `data` cannot name:
  the cases mint them (`ApiExt.ExtCase.device_tokens/2`).
  """

  alias Data.Devices
  alias Data.Extension
  alias Data.JobParts
  alias Data.Scope

  @doc "A live device of `scope`'s person: Chrome on macOS, extension 0.1.0, unless said otherwise."
  def device_fixture(%Scope{} = scope, attrs \\ %{}) do
    now = DateTime.utc_now()

    {:ok, device} =
      attrs
      |> Enum.into(%{
        organisation_id: Scope.organisation_id(scope),
        user_id: Scope.user_id(scope),
        name: "Chrome on macOS",
        agent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) Chrome/130.0 Safari/537.36",
        extension_version: "0.1.0",
        connected_at: now,
        last_seen_at: now
      })
      |> Devices.create()

    device
  end

  @doc "A signals row of `job`, observed now by nobody, with `attrs`' facts (proposals 10–15 by default)."
  def signal_fixture(job, attrs \\ %{}) do
    {:ok, signal} =
      attrs
      |> Enum.into(%{
        organisation_id: job.organisation_id,
        job_id: job.id,
        observed_at: DateTime.utc_now(),
        proposals_min: 10,
        proposals_max: 15
      })
      |> JobParts.add_signal()

    signal
  end

  @doc """
  A new published version of `site`'s selector document: `body:` as given,
  else a minimal contract-1 document unique to this call.
  """
  def config_fixture(site, attrs \\ %{}) do
    attrs = Map.new(attrs)
    n = System.unique_integer([:positive])

    body =
      attrs[:body] ||
        Jason.encode!(%{
          site: to_string(site),
          contract: 1,
          pages: %{job: %{url: ["/jobs/#{n}"], ready: ["h1"]}},
          fields: %{title: %{on: "job", css: ["h1"], read: "text", required: true}},
          identity: %{css: ["a.me"], read: "href"}
        })

    {:ok, {:published, config}} =
      Extension.publish(site, body, attrs[:published_at] || DateTime.utc_now())

    config
  end
end
