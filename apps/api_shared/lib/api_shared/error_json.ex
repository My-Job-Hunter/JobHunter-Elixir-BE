defmodule ApiShared.ErrorJSON do
  @moduledoc """
  Renders every error body, so the shape is defined in exactly one place.

  Phoenix also calls this for errors it raises itself (a 404 from the router,
  a 500 from a crash), which is why the `render/2` clauses exist — without
  them an unmatched route would return Phoenix's default shape and the
  contract would hold everywhere except the edges.
  """

  def error(%{code: code, message: message, details: details}) do
    %{error: %{code: code, message: message, details: details}}
  end

  def render("404.json", _assigns) do
    %{error: %{code: "not_found", message: "We could not find that.", details: %{}}}
  end

  def render("401.json", _assigns) do
    %{error: %{code: "unauthenticated", message: "You need to sign in to do that.", details: %{}}}
  end

  def render("500.json", _assigns) do
    %{error: %{code: "internal_error", message: "Something went wrong at our end.", details: %{}}}
  end

  # Any other status Phoenix raises, named from its own status code.
  def render(template, _assigns) do
    %{
      error: %{
        code: Phoenix.Controller.status_message_from_template(template),
        message: "Request failed.",
        details: %{}
      }
    }
  end
end
