defmodule Api.TeamChannel do
  @moduledoc """
  `team:<id>`: a team's board — `task_created`, `task_updated`,
  `task_deleted` `{task}`. The team's open members join, and the
  organisation's admins. (AQ-02 §7.4, §7.6; PLAN §15.6.)

  **Ids only, and outbound only**: a client re-reads through the API, where
  the scope applies, so a broadcast cannot leak a field; nothing is written
  over a channel. Who may join is `Core.Realtime.may_join?/2`'s; a refused
  join gives no reason, whether the row exists or not.
  """

  use Phoenix.Channel

  alias Core.Realtime

  @impl Phoenix.Channel
  def join("team:" <> _id = topic, _payload, socket) do
    if Realtime.may_join?(socket.assigns.user_id, topic),
      do: {:ok, socket},
      else: {:error, %{reason: "unauthorized"}}
  end

  @impl Phoenix.Channel
  def handle_in(_event, _payload, socket), do: {:reply, {:error, %{reason: "read_only"}}, socket}
end
