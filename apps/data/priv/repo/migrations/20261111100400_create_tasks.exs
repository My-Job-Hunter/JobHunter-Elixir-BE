defmodule Data.Repo.Migrations.CreateTasks do
  use Ecto.Migration

  @moduledoc """
  A task on the board (AQ-02 §5.1). It belongs to **one team** (AQ-03B §4:
  the board it shows on; a team is archived, never deleted, so the key
  restricts), and who of the team sees it is the team's `peer_tasks`. It
  may be **about a customer** and one of their profiles, and may be **shown
  to** or **given to** that customer (`customer_access`, QP2-2) — a column
  rather than a participant row, so a customer who has not signed in yet
  can still be given one.

  The six states are mCart's; Archived is a flag (`archived_at`), not a
  state (QP2-12). Each state's own columns are held to it by a CHECK:
  `held_at` with On hold, `done_at` with Done, `closed_at` and a reason with
  Closed, a stage only In progress. `lead_id` (AQ-04A §5.4) is the lead a
  task is about: a purged lead unlinks its tasks, never deletes them; P4a
  writes nothing to it (P4b's lead page does), and this migration runs
  after `create_leads` for it.
  """

  def change do
    create table(:tasks, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(:organisation_id, references(:organisations, type: :uuid, on_delete: :delete_all),
        null: false
      )

      add(:team_id, references(:teams, type: :uuid, on_delete: :restrict), null: false)
      add(:customer_id, references(:customers, type: :uuid, on_delete: :delete_all))
      add(:profile_id, references(:profiles, type: :uuid, on_delete: :nilify_all))
      add(:lead_id, references(:leads, type: :uuid, on_delete: :nilify_all))
      add(:author_user_id, references(:users, type: :uuid, on_delete: :nilify_all))
      add(:source, :string, null: false, default: "staff")
      add(:title, :string, null: false)
      add(:description, :text)
      add(:state, :string, null: false, default: "todo")
      add(:stage_id, references(:task_stages, type: :uuid, on_delete: :nilify_all))
      add(:priority, :string)
      add(:due_at, :timestamptz)
      add(:due_on, :date)
      add(:reminder_minutes, :smallint)
      add(:customer_access, :string, null: false, default: "none")
      add(:held_at, :timestamptz)
      add(:hold_reason, :text)
      add(:held_from_state, :string)
      add(:done_at, :timestamptz)
      add(:done_by_user_id, references(:users, type: :uuid, on_delete: :nilify_all))
      add(:closed_at, :timestamptz)
      add(:closed_reason, :string)
      add(:closed_note, :text)
      add(:closed_by_user_id, references(:users, type: :uuid, on_delete: :nilify_all))
      add(:archived_at, :timestamptz)
      add(:archived_by_user_id, references(:users, type: :uuid, on_delete: :nilify_all))

      timestamps()
    end

    create(constraint(:tasks, :source_known, check: "source IN ('staff','customer')"))

    create(
      constraint(:tasks, :state_known,
        check: "state IN ('draft','todo','in_progress','on_hold','done','closed')"
      )
    )

    # Null is *normal*: "not triaged" is not a rung of its own (mCart).
    create(
      constraint(:tasks, :priority_known,
        check: "priority IS NULL OR priority IN ('low','high','urgent')"
      )
    )

    create(
      constraint(:tasks, :customer_access_known,
        check: "customer_access IN ('none','shared','assigned')"
      )
    )

    create(
      constraint(:tasks, :closed_reason_known,
        check:
          "closed_reason IS NULL OR closed_reason IN ('not_needed','wont_do','duplicate','withdrawn')"
      )
    )

    create(
      constraint(:tasks, :held_from_state_known,
        check: "held_from_state IS NULL OR held_from_state IN ('todo','in_progress')"
      )
    )

    create(
      constraint(:tasks, :reminder_minutes_known,
        check: "reminder_minutes IS NULL OR reminder_minutes IN (0, 60, 1440)"
      )
    )

    create(
      constraint(:tasks, :title_present,
        check: "btrim(title) <> '' AND char_length(title) <= 200"
      )
    )

    # A due is a time or a day, never both; a reminder needs a time.
    create(constraint(:tasks, :one_due, check: "num_nonnulls(due_at, due_on) <= 1"))

    create(
      constraint(:tasks, :reminder_needs_due_at,
        check: "reminder_minutes IS NULL OR due_at IS NOT NULL"
      )
    )

    create(
      constraint(:tasks, :customer_access_needs_customer,
        check: "customer_id IS NOT NULL OR customer_access = 'none'"
      )
    )

    create(
      constraint(:tasks, :profile_needs_customer,
        check: "profile_id IS NULL OR customer_id IS NOT NULL"
      )
    )

    # A task the customer made is always one they see (§9).
    create(
      constraint(:tasks, :customer_source_shown,
        check: "source <> 'customer' OR customer_access <> 'none'"
      )
    )

    create(
      constraint(:tasks, :hold_matches_state,
        check: "(state = 'on_hold') = (held_at IS NOT NULL)"
      )
    )

    create(
      constraint(:tasks, :hold_has_reason,
        check:
          "held_at IS NULL OR (hold_reason IS NOT NULL AND btrim(hold_reason) <> '' " <>
            "AND held_from_state IS NOT NULL)"
      )
    )

    create(
      constraint(:tasks, :hold_fields_only_on_hold,
        check: "held_at IS NOT NULL OR (hold_reason IS NULL AND held_from_state IS NULL)"
      )
    )

    create(
      constraint(:tasks, :done_matches_state, check: "(state = 'done') = (done_at IS NOT NULL)")
    )

    create(
      constraint(:tasks, :closed_matches_state,
        check: "(state = 'closed') = (closed_at IS NOT NULL AND closed_reason IS NOT NULL)"
      )
    )

    create(
      constraint(:tasks, :stage_only_in_progress,
        check: "stage_id IS NULL OR state = 'in_progress'"
      )
    )

    create(
      index(:tasks, [:organisation_id, :team_id, :state],
        where: "archived_at IS NULL",
        name: :tasks_board_index
      )
    )

    create(
      index(:tasks, [:customer_id, :state],
        where: "archived_at IS NULL",
        name: :tasks_customer_board_index
      )
    )

    # The due scan (`Core.Workers.TaskDueScan`).
    create(
      index(:tasks, [:state, :due_at],
        where: "state IN ('todo','in_progress')",
        name: :tasks_due_scan_index
      )
    )

    # The board indexes above are partial; a cascade from an organisation or
    # a customer reaches the archived rows too.
    create(index(:tasks, [:organisation_id]))
    create(index(:tasks, [:customer_id]))
    create(index(:tasks, [:lead_id]))
    create(index(:tasks, [:team_id]))
    create(index(:tasks, [:profile_id]))
    create(index(:tasks, [:author_user_id]))
    create(index(:tasks, [:stage_id]))
    create(index(:tasks, [:done_by_user_id]))
    create(index(:tasks, [:closed_by_user_id]))
    create(index(:tasks, [:archived_by_user_id]))

    execute(
      "CREATE TRIGGER touch_updated_at BEFORE UPDATE ON tasks " <>
        "FOR EACH ROW EXECUTE FUNCTION touch_updated_at()",
      "DROP TRIGGER IF EXISTS touch_updated_at ON tasks"
    )
  end
end
