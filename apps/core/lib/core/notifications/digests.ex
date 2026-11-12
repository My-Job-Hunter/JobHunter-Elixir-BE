defmodule Core.Notifications.Digests do
  @moduledoc """
  The digest scan (AQ-08 §7.4, QP8-12), run every five minutes by
  `Core.Workers.DigestScan` and by the dev sweeps. **Idempotent**: a person
  is due once their digest time has passed today in their zone, and the
  digest is ensured as `account.digest` keyed by that local date, so a
  second scan that day finds it there.

  It says the person's unread notifications of digest kinds, in groups
  whose digest switch is on, since their last digest (the first covers 24
  hours); nothing to say means no digest. It reaches the person through
  the ordinary pipeline: the bell, and email at once (the `account` group,
  which passes quiet hours and is never skipped as read).
  """

  alias Core.Notifications
  alias Core.Notifications.Digest
  alias Data.Notifications, as: Store
  alias Data.Notifications.Preferences
  alias Data.Scope

  @day 86_400

  @doc "Runs the scan at `now`. Answers how many digests it wrote."
  @spec scan(DateTime.t()) :: non_neg_integer()
  def scan(%DateTime{} = now) do
    groups = Enum.map(Store.groups(), &%{key: &1.key, label: &1.label})
    digest_groups = digest_groups()

    Store.digest_candidates_for_system()
    |> Enum.count(&(write(&1, groups, digest_groups, now) == :written))
  end

  # The groups with a kind that the digest collects.
  defp digest_groups do
    for k <- Store.kinds(),
        "digest" in k.default_channels,
        uniq: true,
        do: k.notification_group_key
  end

  defp write(%{user_id: user_id} = person, groups, digest_groups, now) do
    with {:due, date} <- Digest.due(person.digest_time, person.zone, now),
         key = Digest.key(user_id, date),
         false <- Store.exists?(user_id, key),
         rows = Store.unread_for_digest(user_id, since(user_id, now), on(user_id, digest_groups)),
         %{} = digest <- Digest.compose(rows, groups) do
      organisation_id = List.last(rows).organisation_id

      {:ok, row} =
        Notifications.ensure(
          Scope.system(%{id: organisation_id}),
          %{
            organisation_id: organisation_id,
            user_id: user_id,
            notification_kind_key: "account.digest",
            title: digest.title,
            body: digest.body,
            link_path: "/notifications?unread=1",
            dedupe_key: key
          },
          now
        )

      if row.is_new, do: Notifications.created([row])
      :written
    else
      _not_due_written_or_nothing -> :none
    end
  end

  # Since the person's latest digest, else the last 24 hours.
  defp since(user_id, now),
    do: Store.latest_at(user_id, "account.digest") || DateTime.add(now, -@day, :second)

  defp on(user_id, digest_groups) do
    off = Preferences.off_groups(user_id, :digest)
    Enum.reject(digest_groups, &(&1 in off))
  end
end
