defmodule Api.World.Extension do
  @moduledoc """
  P5's part of `mix aq.world` (AQ-05 §13): three channels with made-up
  handles, over HTTP as Super Admin, as the rest of the world is made —

  - Tanweer's LinkedIn (`linkedin.com/in/tanweer`, already the world's)
    linked to *Golang backend*;
  - an Upwork account for Tanweer, `operated_by: agency`,
    `upwork.com/freelancers/~01aa00bb11cc22dd33`, linked to *Golang
    backend* too, so the Upwork panel picks it;
  - a LinkedIn for Naveed, `operated_by: customer`,
    `linkedin.com/in/naveed-example`, linked to both his profiles.

  P9's (AQ-09 §13 step 0, `email/2`): an email channel each for Tanweer
  (`tanweer@example.com`, *Golang backend*) and Naveed
  (`naveed@example.com`, both his profiles), `listens_via: forwarding`,
  `operated_by: customer`; each gets its forwarding address on creation.

  It replays nothing else new: devices and tokens are never in a snapshot,
  and the selector documents are the reference seed's.
  """

  alias Api.World.Http
  alias Api.World.Snapshot

  @team "/team/v1"

  @doc "The three channels, and their profiles' links."
  def channels(w, snap) do
    tanweer = customer(w, snap, "Tanweer")
    naveed = customer(w, snap, "Naveed")

    linkedin =
      w
      |> Http.call(w.admin, :get, "#{@team}/customers/#{tanweer}/channels")
      |> Enum.find(&(&1["kind"] == "linkedin")) ||
        Mix.raise("Tanweer's LinkedIn is not in the world")

    upwork =
      Http.call(w, w.admin, :post, "#{@team}/customers/#{tanweer}/channels", %{
        kind: "upwork",
        label: "Upwork",
        handle: "https://www.upwork.com/freelancers/~01aa00bb11cc22dd33",
        operated_by: "agency",
        listens_via: "extension"
      })

    naveed_in =
      Http.call(w, w.admin, :post, "#{@team}/customers/#{naveed}/channels", %{
        kind: "linkedin",
        label: "LinkedIn",
        handle: "https://www.linkedin.com/in/naveed-example/",
        operated_by: "customer",
        listens_via: "extension"
      })

    link(w, profile(w, snap, "Tanweer", "Golang backend"), [linkedin["id"], upwork["id"]])

    for title <- ["Elixir backend", "Golang"],
        do: link(w, profile(w, snap, "Naveed", title), [naveed_in["id"]])

    channels = %{"tanweer_upwork" => upwork["id"], "naveed_linkedin" => naveed_in["id"]}
    %{w | channels: Map.merge(w.channels, channels)}
  end

  @doc "P9's two email channels, and their profiles' links."
  def email(w, snap) do
    made =
      for {name, address, titles} <- [
            {"Tanweer", "tanweer@example.com", ["Golang backend"]},
            {"Naveed", "naveed@example.com", ["Elixir backend", "Golang"]}
          ],
          into: %{} do
        channel =
          Http.call(
            w,
            w.admin,
            :post,
            "#{@team}/customers/#{customer(w, snap, name)}/channels",
            %{
              kind: "email",
              label: "Gmail",
              handle: address,
              operated_by: "customer",
              listens_via: "forwarding"
            }
          )

        for title <- titles, do: link(w, profile(w, snap, name, title), [channel["id"]])
        {String.downcase(name) <> "_email", channel["id"]}
      end

    %{w | channels: Map.merge(w.channels, made)}
  end

  # A profile's channels become `ids` added to what it has.
  defp link(w, profile_id, ids) do
    have = Http.call(w, w.admin, :get, "#{@team}/profiles/#{profile_id}")["channel_ids"] || []

    Http.call(w, w.admin, :put, "#{@team}/profiles/#{profile_id}/channels", %{
      channel_ids: Enum.uniq(have ++ ids)
    })
  end

  defp customer(w, snap, name) do
    old = Enum.find(snap["customers"], &(&1["display_name"] == name)) || Mix.raise("no #{name}")
    Map.fetch!(w.customers, old["id"])
  end

  defp profile(w, snap, customer, title) do
    owner = Enum.find(snap["customers"], &(&1["display_name"] == customer))

    old =
      snap
      |> Snapshot.rows("profiles")
      |> Enum.find(&(&1["customer_id"] == owner["id"] and &1["title"] == title)) ||
        Mix.raise("no #{customer} · #{title}")

    Map.fetch!(w.profiles, old["id"])
  end
end
