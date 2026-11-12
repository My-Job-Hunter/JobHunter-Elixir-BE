defmodule ApiExt.ConversationController do
  @moduledoc """
  *Capture conversation* (AQ-06 §9, §11.6): `POST /ext/v1/conversations/capture`,
  always 200 (a retry adds nothing). `Core.Ingest.Conversation` decides.
  """

  use Phoenix.Controller, formats: [:json]

  alias ApiShared.ConversationsJSON
  alias Core.Clock
  alias Core.Ingest.Conversation

  action_fallback ApiShared.FallbackController

  def capture(conn, params) do
    with {:ok, answer} <- Conversation.capture(conn.assigns.scope, params, Clock.now()),
         do: json(conn, ConversationsJSON.captured(answer))
  end
end
