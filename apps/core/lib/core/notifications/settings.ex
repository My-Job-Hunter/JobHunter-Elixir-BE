defmodule Core.Notifications.Settings do
  @moduledoc """
  Notifications › Settings (AQ-08 §8, §11.4, QP8-6), **each person their
  own**: every read and write is bound to the scope's user.

  - **The switches:** a row per group, in their order with `account` last;
    a switch per channel the group's kinds use (`uses`, within `push ·
    email · extension · digest`, without `extension` for a customer). Each
    is on until turned off, and on brings back the kinds' defaults
    (off-only). In-app is always on; Account can't be turned off.
  - **Quiet hours and the digest** sit under them, saved through P1's `PUT
    /me/settings`; this answer carries them, the person's zone, and what
    they have (`has.push`: a browser turned on in this app; `has.extension`:
    a connected device, never for a customer).
  """

  alias Data.Devices
  alias Data.Notifications, as: Store
  alias Data.Notifications.{Preference, Preferences, PushSubscriptions}
  alias Data.Scope

  @channels ~w(push email extension digest)
  @not_used "This group doesn't use it."

  @doc "`GET /notifications/settings` from `app` (`:team` or `:client`): **settings**."
  @spec get(Scope.t(), atom()) :: {:ok, map()} | {:error, term()}
  def get(%Scope{} = scope, app) do
    with {:ok, who} <- me(scope), do: {:ok, view(who, app)}
  end

  @doc """
  `PUT /notifications/settings/groups/:key` with `{push?, email?,
  extension?, digest?}` (booleans): the group's switches, then the
  settings. 404 for an unknown group; 422 on `group` for one that can't be
  turned off, on a channel the group doesn't use, on `extension` for a
  customer, and on a value that isn't true or false.
  """
  @spec put_group(Scope.t(), String.t(), map(), atom(), DateTime.t()) ::
          {:ok, map()} | {:error, term()}
  def put_group(%Scope{} = scope, key, params, app, %DateTime{} = now) do
    params = Map.new(params, fn {k, v} -> {to_string(k), v} end)

    with {:ok, who} <- me(scope),
         %{} = group <- Store.get_group(key) || {:error, :not_found},
         :ok <- can_disable(group),
         {:ok, given} <- switches(params, uses(group.key, who.customer?), who.customer?) do
      current = who.user.id |> Preferences.get(group.key) |> Preference.switches()
      {:ok, _row} = Preferences.put(who.user.id, group.key, Map.merge(current, given), now)
      {:ok, view(who, app)}
    end
  end

  defp can_disable(%{can_disable: true}), do: :ok

  defp can_disable(_account),
    do: {:error, {:invalid, %{"group" => ["These can't be turned off."]}}}

  defp switches(params, uses, customer?) do
    {given, errors} =
      Enum.reduce(@channels, {%{}, %{}}, fn channel, {given, errors} ->
        case Map.fetch(params, channel) do
          :error -> {given, errors}
          {:ok, value} -> check(channel, value, uses, customer?, given, errors)
        end
      end)

    if errors == %{}, do: {:ok, given}, else: {:error, {:invalid, errors}}
  end

  defp check("extension", _value, _uses, true, given, errors),
    do: {given, Map.put(errors, "extension", ["The extension is for the team."])}

  defp check(channel, value, uses, _customer?, given, errors) do
    cond do
      not is_boolean(value) -> {given, Map.put(errors, channel, ["must be true or false"])}
      channel not in uses -> {given, Map.put(errors, channel, [@not_used])}
      true -> {Map.put(given, String.to_existing_atom(channel), value), errors}
    end
  end

  # ── The answer ──────────────────────────────────────────────────────────────

  defp view(who, app) do
    user_id = who.user.id
    prefs = Preferences.for_user(user_id)
    uses = uses_by_group(who.customer?)

    groups =
      for g <- Store.groups() do
        switches = Preference.switches(prefs[g.key])

        %{
          key: g.key,
          label: g.label,
          can_disable: g.can_disable,
          uses: Map.get(uses, g.key, []),
          push: switches.push,
          email: switches.email,
          extension: switches.extension,
          digest: switches.digest
        }
      end

    s = who.settings

    %{
      groups: groups,
      quiet_hours: %{from: hh_mm(s.quiet_hours_start), to: hh_mm(s.quiet_hours_end)},
      digest: %{on: s.digest_on, at: hh_mm(s.digest_time)},
      zone: who.zone,
      has: %{
        push: PushSubscriptions.any?(user_id, app),
        extension: not who.customer? and Devices.connected?(user_id)
      }
    }
  end

  @doc """
  The channels each group's kinds use, within `push · email · extension ·
  digest` and in that order, without `extension` for a customer: `%{group
  => [channel]}`.
  """
  @spec uses_by_group(boolean()) :: %{String.t() => [String.t()]}
  def uses_by_group(customer?) do
    channels = if customer?, do: @channels -- ["extension"], else: @channels

    Store.kinds()
    |> Enum.group_by(& &1.notification_group_key, & &1.default_channels)
    |> Map.new(fn {group, lists} ->
      used = List.flatten(lists)
      {group, Enum.filter(channels, &(&1 in used))}
    end)
  end

  defp uses(group, customer?), do: Map.get(uses_by_group(customer?), group, [])

  defp hh_mm(nil), do: nil
  defp hh_mm(%Time{} = t), do: t |> Time.to_iso8601() |> binary_part(0, 5)

  defp me(scope) do
    with id when is_binary(id) <- Scope.user_id(scope),
         %{} = who <- Store.recipient(id) do
      {:ok, who}
    else
      _nobody -> {:error, :not_found}
    end
  end
end
