defmodule Api.World.Conversations do
  @moduledoc """
  P6's part of `mix aq.world` (AQ-06 §13 step 0, §14, QP6-24): two
  contacts, made over HTTP as Fiza with `POST /team/v1/contacts`, as the
  rest of the world is made —

  - *Mei Chen*, Talent Partner (recruiter) at Juniper Edge,
    `mei.chen@juniperedge.example`, LinkedIn
    `https://www.linkedin.com/in/mei-chen-example/`;
  - *Omar Haddad*, hiring manager at Corvid Security,
    `omar.haddad@corvid.example`.

  The three made-up `.eml` files of one thread are `apps/core/priv/eml/`'s,
  uploaded in the run (§13 step 3), not here: the run proves the paths
  from empty.
  """

  alias Api.World.Http
  alias Api.World.Snapshot

  @team "/team/v1"

  @doc "The two contacts."
  def contacts(w, snap) do
    fiza = Snapshot.user_by_email(snap, "fiza@example.com")

    mei =
      Http.call(w, fiza, :post, "#{@team}/contacts", %{
        name: "Mei Chen",
        title: "Talent Partner",
        company_id: company(w, fiza, "Juniper Edge"),
        time_zone: "Asia/Singapore",
        handles: [
          %{kind: "email", value: "mei.chen@juniperedge.example"},
          %{kind: "linkedin", value: "https://www.linkedin.com/in/mei-chen-example/"}
        ]
      })

    omar =
      Http.call(w, fiza, :post, "#{@team}/contacts", %{
        name: "Omar Haddad",
        title: "Hiring manager",
        company_id: company(w, fiza, "Corvid Security"),
        handles: [%{kind: "email", value: "omar.haddad@corvid.example"}]
      })

    Map.put(w, :contacts, %{"mei" => mei["id"], "omar" => omar["id"]})
  end

  defp company(w, who, name) do
    w
    |> Http.call(who, :get, "#{@team}/companies?q=#{URI.encode_www_form(name)}")
    |> Enum.find(&(&1["name"] == name))
    |> case do
      %{"id" => id} -> id
      nil -> Mix.raise("#{name} is not in the world")
    end
  end
end
