defmodule Data.Notifications.Notification do
  @moduledoc """
  One person's notification (AQ-02 §5.2): frozen words in the recipient's
  terms, where it opens, and whether it was read. Written only through
  `Data.Notifications.ensure/2`.
  """

  use Data.Schema

  alias Data.Accounts.User
  alias Data.Leads.Lead
  alias Data.Notifications.Kind
  alias Data.Organisations.Organisation
  alias Data.Tasks.Task

  @type t :: %__MODULE__{}

  schema "notifications" do
    field(:title, :string)
    field(:body, :string)
    field(:link_path, :string)
    field(:dedupe_key, :string)
    field(:read_at, :utc_datetime_usec)
    # Set by `Data.Notifications.ensure/2`: whether this call wrote the row.
    field(:is_new, :boolean, virtual: true, default: false)

    belongs_to(:organisation, Organisation)
    belongs_to(:user, User)
    belongs_to(:actor_user, User)
    belongs_to(:task, Task)
    belongs_to(:lead, Lead)
    belongs_to(:approval, Data.Approvals.Approval)

    belongs_to(:notification_kind, Kind,
      foreign_key: :notification_kind_key,
      references: :key,
      type: :string
    )

    timestamps()
  end

  @doc """
  Where a push or a pop-up opens it (AQ-08 §11.4): the row's link with
  `n=<id>`, so the app marks it read on arrival. A path, never an origin.

      iex> Data.Notifications.Notification.open_path(%{id: "n1", link_path: "/leads/7"})
      "/leads/7?n=n1"
      iex> Data.Notifications.Notification.open_path(%{id: "n1", link_path: "/triage?team=3"})
      "/triage?team=3&n=n1"
      iex> Data.Notifications.Notification.open_path(%{id: "n1", link_path: nil})
      "/notifications?n=n1"
  """
  @spec open_path(map()) :: String.t()
  def open_path(%{id: id, link_path: path}) do
    path = path || "/notifications"
    separator = if String.contains?(path, "?"), do: "&", else: "?"
    path <> separator <> "n=" <> to_string(id)
  end

  def changeset(notification, attrs) do
    notification
    |> cast(attrs, [
      :organisation_id,
      :user_id,
      :notification_kind_key,
      :actor_user_id,
      :task_id,
      :lead_id,
      :approval_id,
      :title,
      :body,
      :link_path,
      :dedupe_key
    ])
    |> update_change(:title, &(&1 && String.slice(&1, 0, 255)))
    |> validate_required([
      :organisation_id,
      :user_id,
      :notification_kind_key,
      :title,
      :dedupe_key
    ])
    |> check_constraint(:title, name: :title_present, message: "can't be blank")
    |> check_constraint(:lead_id, name: :one_subject, message: "names one subject at most")
    |> foreign_key_constraint(:notification_kind_key)
    |> foreign_key_constraint(:user_id)
  end
end
