defmodule Api.InfoController do
  @moduledoc """
  The root `GET /info`: which service this is, and which build. Unauthenticated,
  because "which build is on staging?" is a question you need answered
  *before* you can sign in to find out.

  Two keys, `name` and `version`, and the frontend's P0 brief fixes both. The
  per-app `/team/v1/info` (`ApiShared.InfoController`) is the one a client
  reads; this one is for a deploy pipeline and a person with curl.

  mCart's also reports the commit, read with `git rev-parse` at compile
  time. Not here: this repository's rule is that **nothing in the build runs
  git** (CLAUDE.md), and a release has no `.git` to read anyway, so the field
  would say `unknown` exactly where it mattered.
  """

  use Phoenix.Controller, formats: [:json]

  # Read at compile time: a release has no Mix.
  @version Mix.Project.config()[:version]

  def show(conn, _params) do
    json(conn, %{name: "autoqare", version: @version})
  end
end
