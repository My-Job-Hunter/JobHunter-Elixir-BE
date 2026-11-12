defmodule Data.Tasks.Link do
  @moduledoc """
  A web link on a task (AQ-02 §5.1). **Fails closed** through
  `Utils.SafeUrl`: an unsafe scheme becomes no URL at all rather than a
  stored value filtered at render. Unlabelled, it reads as its host.
  """

  use Data.Schema

  alias Data.Accounts.User
  alias Data.Tasks.Task
  alias Utils.SafeUrl

  @type t :: %__MODULE__{}

  schema "task_links" do
    field(:url, :string)
    field(:label, :string)
    field(:position, :integer, default: 0)

    belongs_to(:task, Task)
    belongs_to(:added_by_user, User)

    timestamps()
  end

  def changeset(link, attrs) do
    link
    |> cast(attrs, [:task_id, :url, :label, :position, :added_by_user_id])
    |> update_change(:url, &SafeUrl.sanitise/1)
    |> update_change(:label, &Utils.presence/1)
    |> validate_required([:task_id])
    |> require_url()
    |> put_label()
    |> validate_length(:label, max: 200)
    |> validate_length(:url, max: 2000)
    |> check_constraint(:url, name: :url_shape, message: "must start http:// or https://")
    |> unique_constraint(:url,
      name: :task_links_task_id_url_index,
      message: "is already on this task"
    )
    |> foreign_key_constraint(:task_id)
  end

  defp require_url(changeset) do
    if get_field(changeset, :url),
      do: changeset,
      else: add_error(changeset, :url, "must be a web address starting http:// or https://")
  end

  defp put_label(changeset) do
    case {get_field(changeset, :label), get_field(changeset, :url)} do
      {nil, url} when is_binary(url) -> put_change(changeset, :label, SafeUrl.host(url))
      _labelled -> changeset
    end
  end
end
