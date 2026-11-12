defmodule Api.LeadChannel do
  @moduledoc """
  `lead:<id>`: one lead's page (AQ-04B §8.3) — `event_added {lead}` when its
  ledger may have grown, `notes_changed {lead}` when a note was added,
  edited or deleted. Whoever reads the lead joins (its team by
  `peer_leads`, the system admin), and its customer.

  **Ids only, and outbound only**: a client re-reads through the API, where
  the scope applies, so a broadcast cannot leak a staff-only row; nothing is
  written over a channel. Who may join is `Core.Realtime.may_join?/2`'s; a
  refused join gives no reason, whether the lead exists or not.
  """

  use Phoenix.Channel

  alias Core.Realtime

  @impl Phoenix.Channel
  def join("lead:" <> _id = topic, _payload, socket) do
    if Realtime.may_join?(socket.assigns.user_id, topic),
      do: {:ok, socket},
      else: {:error, %{reason: "unauthorized"}}
  end

  @impl Phoenix.Channel
  def handle_in(_event, _payload, socket), do: {:reply, {:error, %{reason: "read_only"}}, socket}
end
