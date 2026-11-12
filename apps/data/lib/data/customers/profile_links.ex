defmodule Data.Customers.ProfileMember do
  @moduledoc "An owner of a profile (AQ-01 §4.3; PLAN §3.2): the staff who hunt for it."

  use Data.Schema

  alias Data.Accounts.User
  alias Data.Customers.Profile

  @type t :: %__MODULE__{}

  schema "profile_members" do
    field(:since_on, :date)

    belongs_to(:profile, Profile)
    belongs_to(:user, User)
  end

  def changeset(link, attrs) do
    link
    |> cast(attrs, [:profile_id, :user_id, :since_on])
    |> validate_required([:profile_id, :user_id, :since_on])
    |> unique_constraint([:profile_id, :user_id], message: "already owns this profile")
    |> foreign_key_constraint(:profile_id)
    |> foreign_key_constraint(:user_id)
  end
end

defmodule Data.Customers.ProfileSkill do
  @moduledoc "A profile's skill with its level (AQ-01 §4.3)."

  use Data.Schema

  alias Data.Customers.{Profile, Skill}

  @levels Data.Vocabulary.skill_levels() |> Enum.map(&String.to_atom/1)

  @type t :: %__MODULE__{}

  schema "profile_skills" do
    field(:level, Ecto.Enum, values: @levels, default: :working)
    field(:years, :integer)

    belongs_to(:profile, Profile)
    belongs_to(:skill, Skill)
  end

  def changeset(link, attrs) do
    link
    |> cast(attrs, [:profile_id, :skill_id, :level, :years])
    |> validate_required([:profile_id, :skill_id, :level])
    |> validate_number(:years, greater_than_or_equal_to: 0, less_than: 80)
    |> check_constraint(:level, name: :level_known)
    |> unique_constraint([:profile_id, :skill_id], message: "is already on the profile")
    |> foreign_key_constraint(:profile_id)
    |> foreign_key_constraint(:skill_id)
  end
end

defmodule Data.Customers.ProfileChannel do
  @moduledoc "A channel a profile works through (AQ-01 §4.3; PLAN §4)."

  use Data.Schema

  alias Data.Customers.{Channel, Profile}

  @type t :: %__MODULE__{}

  schema "profile_channels" do
    belongs_to(:profile, Profile)
    belongs_to(:channel, Channel)
  end

  def changeset(link, attrs) do
    link
    |> cast(attrs, [:profile_id, :channel_id])
    |> validate_required([:profile_id, :channel_id])
    |> unique_constraint([:profile_id, :channel_id], message: "is already linked")
    |> foreign_key_constraint(:profile_id)
    |> foreign_key_constraint(:channel_id)
  end
end

defmodule Data.Customers.ProfileDefaultDocument do
  @moduledoc """
  A profile's default CV (AQ-01 §4.3 `default_document_id`), as a link
  table because `documents` points at `profiles` (see the migration).
  """

  use Data.Schema

  alias Data.Customers.{Document, Profile}

  @type t :: %__MODULE__{}

  schema "profile_default_documents" do
    belongs_to(:profile, Profile)
    belongs_to(:document, Document)
  end

  def changeset(link, attrs) do
    link
    |> cast(attrs, [:profile_id, :document_id])
    |> validate_required([:profile_id, :document_id])
    |> unique_constraint(:profile_id)
    |> foreign_key_constraint(:profile_id)
    |> foreign_key_constraint(:document_id)
  end
end
