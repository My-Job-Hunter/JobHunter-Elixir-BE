defmodule Core.Notifications.PopUps do
  @moduledoc """
  The extension channel (AQ-08 §7.5, QP8-15): the extension's minute poll
  calls `GET /ext/v1/notifications/pop-ups`, which **claims** the person's
  due extension rows in one statement (`UPDATE … RETURNING`, marked sent),
  so a second poll, or a second device, gets nothing. Rows in a group whose
  extension switch is off are skipped first (`preference_off`): pop-ups
  follow the person's settings. A row nobody claims within a day is
  skipped by the sweep (`no_target`).

  Each item opens the console (`config :core, :app_urls`) at the
  notification's link with `n=<id>`, so the console marks it read.
  """

  alias Data.Notifications.{Deliveries, Notification, Preferences}
  alias Data.Scope

  @most 20

  @doc "Claims and answers `{items: [{id, kind, title, body, url, at}]}`, oldest first, at most 20."
  @spec claim(Scope.t(), DateTime.t()) :: {:ok, map()} | {:error, term()}
  def claim(%Scope{} = scope, %DateTime{} = now) do
    case Scope.user_id(scope) do
      nil ->
        {:error, :not_found}

      user_id ->
        off = Preferences.off_groups(user_id, :extension)

        items =
          for n <- Deliveries.claim_extension(user_id, now, @most, off) do
            %{
              id: n.id,
              kind: n.notification_kind_key,
              title: n.title,
              body: n.body,
              url: console() <> Notification.open_path(n),
              at: n.inserted_at
            }
          end

        {:ok, %{items: items}}
    end
  end

  defp console,
    do:
      :core
      |> Application.get_env(:app_urls, [])
      |> Keyword.get(:console, "http://localhost:5800")
end
