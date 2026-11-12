defmodule Api.World.People do
  @moduledoc """
  The first half of `mix aq.world` (AQ-03B §8), over HTTP as each person:
  the organisation's settings, the teams and their settings, the staff
  invitations each accepted with its code, the customers (Tanweer's portal
  account accepted; Sara's invitation left open), their profiles with every
  fact, owners and skills, a channel, the CV through the three-step upload
  and the default document.

  Who acts: Super Admin (`super-admin@example.com`, the one system admin;
  Dawud until 2026-11-12) for the organisation, the teams, the customers and
  their profiles; whoever issued an invitation in the snapshot (Super Admin
  when it says nobody); a team's first lead for its settings; whoever
  uploaded the CV for the document.
  """

  alias Api.World.Http
  alias Api.World.Snapshot

  @team "/team/v1"
  @client "/client/v1"
  @admin_email "super-admin@example.com"

  @doc "Accepts the bootstrap's admin invitation as Super Admin and signs them in."
  def admin(w, snap, code) do
    admin = Snapshot.user_by_email(snap, @admin_email)
    accept(w, snap, admin, code)
    w = put_token(w, admin, login(w, @admin_email))
    me = Http.call(w, admin, :get, @team <> "/me")
    %{w | users: Map.put(w.users, admin, me["user"]["id"]), admin: admin}
  end

  @doc "The organisation's settings as the snapshot has them."
  def organisation(w, snap) do
    [org] = snap["organisations"]
    [settings] = snap["organisation_settings"]

    body =
      org
      |> Map.take(~w(name timezone currency_code country_code))
      |> Map.merge(Snapshot.writable(settings, ["organisation_id"]))
      |> Map.reject(fn {_k, v} -> is_nil(v) end)

    Http.call(w, w.admin, :put, @team <> "/org/settings", body)
    w
  end

  @doc "The teams, by Super Admin."
  def teams(w, snap) do
    Enum.reduce(Snapshot.rows(snap, "teams"), w, fn team, w ->
      made = Http.call(w, w.admin, :post, @team <> "/teams", %{name: team["name"]})
      %{w | teams: Map.put(w.teams, team["id"], made["id"])}
    end)
  end

  @doc """
  The staff invitations, each issued by whoever issued it and accepted with
  the code from the create answer: a new account the first time, a role
  added (signed in) after that.
  """
  def staff(w, snap) do
    snap
    |> Snapshot.rows("invitations")
    |> Enum.filter(&(&1["kind"] == "team_member" and &1["accepted_at"]))
    |> Enum.sort_by(& &1["accepted_at"])
    |> Enum.reduce(w, fn inv, w ->
      made =
        Http.call(w, issuer(w, inv), :post, @team <> "/invitations", %{
          kind: "team_member",
          email: inv["email"],
          invited_name: inv["invited_name"],
          team_id: Map.fetch!(w.teams, inv["team_id"]),
          role: inv["role"]
        })

      who = Snapshot.user_by_email(snap, inv["email"])
      answer = accept(w, snap, who, made["code"])
      w |> put_token(who, answer["access_token"]) |> put_user(who, answer["user"]["id"])
    end)
  end

  @doc """
  Each team's settings, written by its first lead: QT-4's defaults (`view ·
  view · edit`) but where the snapshot shows a deliberate change — Backend
  squad's `members_see_peer_tasks` on (`peer_tasks: view`) and its staff
  names hidden from the customer.
  """
  def team_settings(w, snap) do
    Enum.reduce(snap["team_settings"], w, fn s, w ->
      body = %{
        peer_tasks: "view",
        peer_leads: "view",
        peer_jobs: "edit",
        customer_sees_staff_names: s["customer_sees_staff_names"],
        customer_sees_conversations: s["customer_sees_conversations"],
        customer_sees_job_suggestions: s["customer_sees_job_suggestions"]
      }

      team = Map.fetch!(w.teams, s["team_id"])
      Http.call(w, first_lead(snap, s["team_id"]), :put, "#{@team}/teams/#{team}/settings", body)
      w
    end)
  end

  @doc """
  The customers with their teams (Super Admin), their status, and the portal
  invitations the snapshot has: Tanweer's accepted, Sara's left open.
  """
  def customers(w, snap) do
    Enum.reduce(Snapshot.rows(snap, "customers"), w, fn c, w ->
      teams =
        for t <- snap["customer_teams"], t["customer_id"] == c["id"], do: w.teams[t["team_id"]]

      fields = ~w(display_name email phone_e164 timezone location_text country_code started_on)

      body =
        c
        |> Map.take(fields)
        |> Map.reject(fn {_k, v} -> is_nil(v) end)
        |> Map.put("team_ids", teams)

      made = Http.call(w, w.admin, :post, @team <> "/customers", body)
      w = %{w | customers: Map.put(w.customers, c["id"], made["id"])}
      w = invite(w, snap, c, made["id"])

      if c["status"] in ["paused", "ended"],
        do:
          Http.call(w, w.admin, :post, "#{@team}/customers/#{made["id"]}/status", %{
            status: c["status"]
          })

      w
    end)
  end

  defp invite(w, snap, customer, id) do
    case Enum.find(snap["invitations"], &(&1["customer_id"] == customer["id"])) do
      nil ->
        w

      inv ->
        made = Http.call(w, issuer(w, inv), :post, "#{@team}/customers/#{id}/invite")
        accepted(w, snap, inv, made["code"])
    end
  end

  defp accepted(w, _snap, %{"accepted_at" => nil}, _code), do: w

  defp accepted(w, snap, inv, code) do
    who = Snapshot.user_by_email(snap, inv["email"])
    answer = accept(w, snap, who, code, @client)
    w |> put_token(who, answer["access_token"]) |> put_user(who, answer["user"]["id"])
  end

  @doc "Every profile with its pitch, facts, owners and skills, by Super Admin."
  def profiles(w, snap) do
    Enum.reduce(Snapshot.rows(snap, "profiles"), w, fn p, w ->
      owners =
        for m <- snap["profile_members"], m["profile_id"] == p["id"], do: w.users[m["user_id"]]

      body =
        p |> Snapshot.writable(~w(customer_id status archived_at)) |> Map.put("owner_ids", owners)

      customer = Map.fetch!(w.customers, p["customer_id"])
      made = Http.call(w, w.admin, :post, "#{@team}/customers/#{customer}/profiles", body)

      skills =
        for s <- snap["profile_skills"], s["profile_id"] == p["id"] do
          %{skill_id: skill_id(w, snap, s["skill_id"]), level: s["level"], years: s["years"]}
        end

      if skills != [],
        do: Http.call(w, w.admin, :put, "#{@team}/profiles/#{made["id"]}/skills", skills)

      %{w | profiles: Map.put(w.profiles, p["id"], made["id"])}
    end)
  end

  @doc "The skills the snapshot names that the production seed does not, by Super Admin; then every skill by name."
  def skills(w, snap) do
    have = Map.new(Http.call(w, w.admin, :get, @team <> "/skills"), &{&1["name"], &1["id"]})

    have =
      for s <- Snapshot.rows(snap, "skills"), not Map.has_key?(have, s["name"]), reduce: have do
        acc ->
          made = Http.call(w, w.admin, :post, @team <> "/skills", Map.take(s, ~w(name category)))
          Map.put(acc, made["name"], made["id"])
      end

    %{w | skills: have}
  end

  @doc "The channels, by Super Admin."
  def channels(w, snap) do
    Enum.reduce(Snapshot.rows(snap, "channels"), w, fn ch, w ->
      body = Map.take(ch, ~w(kind handle label operated_by listens_via))
      customer = Map.fetch!(w.customers, ch["customer_id"])
      made = Http.call(w, w.admin, :post, "#{@team}/customers/#{customer}/channels", body)
      %{w | channels: Map.put(w.channels, ch["id"], made["id"])}
    end)
  end

  @doc "Each document's file through the three-step upload, the document, and the default, by the uploader."
  def documents(w, snap) do
    Enum.reduce(Snapshot.rows(snap, "documents"), w, fn doc, w ->
      link = Enum.find(snap["document_media"], &(&1["document_id"] == doc["id"]))
      media = Snapshot.row!(snap, "media", link["media_id"])
      who = media["owner_user_id"]
      media_id = upload(w, who, @team, media)
      body = %{kind: doc["kind"], label: doc["label"], media_id: media_id}
      profile = Map.fetch!(w.profiles, doc["profile_id"])
      made = Http.call(w, who, :post, "#{@team}/profiles/#{profile}/documents", body)

      if Enum.any?(snap["profile_default_documents"], &(&1["document_id"] == doc["id"])),
        do:
          Http.call(w, who, :put, "#{@team}/profiles/#{profile}/default-document", %{
            document_id: made["id"]
          })

      %{w | documents: Map.put(w.documents, doc["id"], made["id"])}
    end)
  end

  @doc "A file of the world through `POST /media`, `PUT` its bytes, confirm; answers the new media id."
  def upload(w, who, prefix, media) do
    bytes = Snapshot.file!(media["original_filename"])

    made =
      Http.call(w, who, :post, prefix <> "/media", %{
        media_kind: media["media_kind"],
        content_type: media["content_type"],
        byte_count: byte_size(bytes),
        original_filename: media["original_filename"]
      })

    Http.upload(w, who, made["upload"], bytes)
    Http.call(w, who, :post, "#{prefix}/media/#{made["id"]}/confirm", %{})
    made["id"]
  end

  # ── Helpers ─────────────────────────────────────────────────────────────────

  @doc "A skill's new id from its old one, by name."
  def skill_id(w, snap, old_id),
    do: Map.fetch!(w.skills, Snapshot.row!(snap, "skills", old_id)["name"])

  defp accept(w, snap, who, code, prefix \\ @team) do
    body = %{name: Snapshot.name(snap, who), password: w.password}
    signed_in = if Map.has_key?(w.tokens, who), do: who, else: nil
    Http.call(w, signed_in, :post, "#{prefix}/auth/invitations/#{code}/accept", body)
  end

  defp login(w, email) do
    Http.call(w, nil, :post, @team <> "/auth/login", %{email: email, password: w.password})[
      "access_token"
    ]
  end

  defp issuer(w, %{"invited_by_user_id" => nil}), do: w.admin
  defp issuer(_w, %{"invited_by_user_id" => who}), do: who

  defp first_lead(snap, team_id) do
    snap
    |> Snapshot.rows("team_members")
    |> Enum.sort_by(& &1["joined_at"])
    |> Enum.find(&(&1["team_id"] == team_id and &1["role"] == "lead"))
    |> Map.fetch!("user_id")
  end

  defp put_token(w, who, token), do: %{w | tokens: Map.put(w.tokens, who, token)}
  defp put_user(w, who, id), do: %{w | users: Map.put(w.users, who, id)}
end
