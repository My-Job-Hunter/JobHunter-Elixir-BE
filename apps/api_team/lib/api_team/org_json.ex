defmodule ApiTeam.OrgJSON do
  @moduledoc "The organisation's shapes (AQ-01 §6.2)."

  alias ApiShared.MeJSON
  alias Data.Organisations.OrganisationSettings

  # The organisation flat, its timings nested: one shape for `GET /org` and
  # `PUT /org/settings`, as the frontend's `org` schema reads it.
  def show(%{organisation: organisation, settings: settings}) do
    organisation
    |> MeJSON.organisation()
    |> Map.put(:settings, Map.new(OrganisationSettings.fields(), &{&1, Map.get(settings, &1)}))
  end

  def audit(%{events: events, next_cursor: cursor}) do
    %{items: Enum.map(events, &event_json/1), next_cursor: cursor}
  end

  defp event_json(e) do
    %{
      id: e.id,
      actor_user_id: e.actor_user_id,
      actor_name: actor_name(e.actor_user),
      subject_label: e.subject_label,
      via: e.via,
      subject_kind: e.subject_kind,
      subject_id: e.subject_id,
      action: e.action,
      before: e.before,
      after: e.after,
      request_id: e.request_id,
      occurred_at: e.occurred_at
    }
  end

  defp actor_name(%{person: %{display_name: name}}), do: name
  defp actor_name(_none), do: nil
end
