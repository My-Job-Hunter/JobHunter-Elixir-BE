defmodule ApiTeam.Router do
  @moduledoc """
  The API for the team console (5800): the system admin, team leads and
  staff. `Api.Endpoint` forwards `/team` here, so `/v1/…` below is
  `/team/v1/…` to a client.

  It includes the shared routes (`ApiShared.Routes`: `/info`, `/auth/*`,
  `/me/*`, `/media/*`) and adds the console's own (AQ-01 §6.2): the
  organisation (*Settings › System*) and its audit log, teams with their members and
  settings, invitations and people; customers with their profiles,
  channels, documents and notes, and the skills vocabulary (P1.2); the
  board — the page, tasks, their verbs, parts and thread, a person's
  stages (AQ-02 §7.2); the job pool — jobs, the check, their verbs,
  suggestions and dismissals, and companies (AQ-03 §7); share links on a
  task, a job or a lead, and opening one (AQ-03B §5.1); leads, their board
  and verbs, and the pipelines (AQ-04A §8.1). P4b (AQ-04B §8.1): the lead page's
  History, notes, follow-ups and labels, the Tracker and its CSV, bulk
  verbs, labels, saved views, the retention preview, Customer › Activity.
  P5 (AQ-05 §11.2): the extension's connect codes and devices, and Settings
  › Extension's health and configs. P6 (AQ-06 §11.1): contacts, a lead's
  contacts, conversations and messages, `.eml`, triage and *Classify*,
  meetings and their ICS. P7 (AQ-07 §11.1): approvals, their verbs and
  comments, a lead's approvals, a customer's approval policies. P8 (AQ-08 §11.3): delivery
  health. Every later phase adds its staff routes here
  (PLAN §15.4).
  """

  use Phoenix.Router

  require ApiShared.Routes

  pipeline :api do
    # `csv` for `GET /tracker.csv` (AQ-04B §8.1) and `ics` for a meeting's
    # calendar file (AQ-06 §8.2) when a client asks for them by type.
    plug :accepts, ["json", "csv", "ics"]
    plug ApiShared.Plugs.App, "team"
  end

  ApiShared.Routes.shared_pipelines()

  # `:aq_shared` puts `cache-control: no-store` on every answer: a version
  # from a proxy is the wrong version, and these carry tokens.
  scope "/v1" do
    pipe_through [:api, :aq_shared]

    ApiShared.Routes.shared_routes()

    scope "/", ApiTeam do
      pipe_through :aq_authenticated

      get "/org", OrgController, :show
      put "/org/settings", OrgController, :update_settings
      get "/org/audit", OrgController, :audit

      get "/teams", TeamController, :index
      post "/teams", TeamController, :create
      get "/teams/:id", TeamController, :show
      patch "/teams/:id", TeamController, :update
      post "/teams/:id/archive", TeamController, :archive
      get "/teams/:id/settings", TeamController, :settings
      put "/teams/:id/settings", TeamController, :put_settings
      get "/teams/:id/members", TeamController, :members
      post "/teams/:id/members/:user_id/role", TeamController, :change_role
      delete "/teams/:id/members/:user_id", TeamController, :remove_member

      get "/invitations", InvitationController, :index
      post "/invitations", InvitationController, :create
      post "/invitations/:id/revoke", InvitationController, :revoke
      post "/invitations/:id/resend", InvitationController, :resend

      get "/people", PeopleController, :index
      post "/people/:user_id/suspend", PeopleController, :suspend
      post "/people/:user_id/unsuspend", PeopleController, :unsuspend

      # Customers (P1.2): the record, its teams, the portal invitation, the notes.
      get "/customers", CustomerController, :index
      post "/customers", CustomerController, :create
      get "/customers/:id", CustomerController, :show
      patch "/customers/:id", CustomerController, :update
      post "/customers/:id/status", CustomerController, :change_status
      post "/customers/:id/teams", CustomerController, :assign_team
      delete "/customers/:id/teams/:team_id", CustomerController, :remove_team
      post "/customers/:id/invite", CustomerController, :invite
      get "/customers/:id/notes", CustomerController, :notes
      get "/customers/:id/activity", CustomerController, :activity
      post "/customers/:id/notes", CustomerController, :create_note
      patch "/notes/:id", CustomerController, :update_note
      delete "/notes/:id", CustomerController, :delete_note

      get "/customers/:id/profiles", ProfileController, :index
      post "/customers/:id/profiles", ProfileController, :create
      get "/profiles/:id", ProfileController, :show
      patch "/profiles/:id", ProfileController, :update
      post "/profiles/:id/archive", ProfileController, :archive
      put "/profiles/:id/owners", ProfileController, :put_owners
      put "/profiles/:id/skills", ProfileController, :put_skills
      put "/profiles/:id/channels", ProfileController, :put_channels

      get "/customers/:id/channels", ChannelController, :index
      post "/customers/:id/channels", ChannelController, :create
      get "/channels/:id", ChannelController, :show
      patch "/channels/:id", ChannelController, :update
      post "/channels/:id/archive", ChannelController, :archive
      post "/channels/:id/inbound-address", ChannelController, :renew_address

      get "/profiles/:id/documents", DocumentController, :index
      post "/profiles/:id/documents", DocumentController, :create
      put "/profiles/:id/default-document", DocumentController, :put_default
      get "/documents/:id", DocumentController, :show
      patch "/documents/:id", DocumentController, :update
      post "/documents/:id/archive", DocumentController, :archive
      post "/documents/:id/new-version", DocumentController, :new_version

      get "/skills", SkillController, :index
      post "/skills", SkillController, :create
      post "/skills/:id/archive", SkillController, :archive

      # The board (AQ-02 §7.2). `search` before `:id`, so it is not an id.
      get "/board", BoardController, :show
      get "/tasks/search", TaskController, :search
      post "/tasks", TaskController, :create
      get "/tasks/:id", TaskController, :show
      patch "/tasks/:id", TaskController, :update
      delete "/tasks/:id", TaskController, :delete
      post "/tasks/:id/start", TaskController, :start
      post "/tasks/:id/move", TaskController, :move
      post "/tasks/:id/hold", TaskController, :hold
      post "/tasks/:id/resume", TaskController, :resume
      post "/tasks/:id/done", TaskController, :done
      post "/tasks/:id/reopen", TaskController, :reopen
      post "/tasks/:id/close", TaskController, :close
      post "/tasks/:id/archive", TaskController, :archive
      post "/tasks/:id/unarchive", TaskController, :unarchive
      put "/tasks/:id/assignees", TaskController, :assignees
      post "/tasks/:id/watch", TaskController, :watch
      post "/tasks/:id/mute", TaskController, :mute
      get "/tasks/:id/history", TaskController, :history

      post "/tasks/:id/checklist", TaskPartController, :add_item
      put "/tasks/:id/checklist/order", TaskPartController, :order_items
      patch "/tasks/:id/checklist/:item_id", TaskPartController, :rename_item
      post "/tasks/:id/checklist/:item_id/toggle", TaskPartController, :toggle_item
      delete "/tasks/:id/checklist/:item_id", TaskPartController, :remove_item
      post "/tasks/:id/steps", TaskPartController, :add_step
      put "/tasks/:id/steps/order", TaskPartController, :order_steps
      patch "/tasks/:id/steps/:step_id", TaskPartController, :update_step
      post "/tasks/:id/steps/:step_id/toggle", TaskPartController, :toggle_step
      post "/tasks/:id/steps/:step_id/nudge", TaskPartController, :nudge_step
      delete "/tasks/:id/steps/:step_id", TaskPartController, :remove_step
      post "/tasks/:id/links", TaskPartController, :add_link
      delete "/tasks/:id/links/:link_id", TaskPartController, :remove_link
      post "/tasks/:id/relations", TaskPartController, :add_relation
      delete "/tasks/:id/relations/:relation_id", TaskPartController, :remove_relation
      post "/tasks/:id/files", TaskPartController, :add_file
      delete "/tasks/:id/files/:media_id", TaskPartController, :remove_file

      get "/tasks/:id/comments", TaskCommentController, :index
      post "/tasks/:id/comments", TaskCommentController, :create
      post "/tasks/:id/comments/:comment_id/replies", TaskCommentController, :reply
      patch "/task-comments/:id", TaskCommentController, :update_comment
      delete "/task-comments/:id", TaskCommentController, :delete_comment
      patch "/task-replies/:id", TaskCommentController, :update_reply
      delete "/task-replies/:id", TaskCommentController, :delete_reply

      # The job pool (AQ-03 §7). `check` before `:id`, so it is not an id.
      get "/jobs", JobController, :index
      post "/jobs/check", JobController, :check
      post "/jobs", JobController, :create
      get "/jobs/:id", JobController, :show
      patch "/jobs/:id", JobController, :update
      put "/jobs/:id/platform-details", JobController, :platform_details
      post "/jobs/:id/close", JobController, :close
      post "/jobs/:id/reopen", JobController, :reopen
      post "/jobs/:id/archive", JobController, :archive
      post "/jobs/:id/unarchive", JobController, :unarchive
      post "/jobs/:id/merge", JobController, :merge
      get "/jobs/:id/suggestions", JobController, :suggestions
      post "/jobs/:id/dismissals", JobController, :dismiss
      delete "/jobs/:id/dismissals/:profile_id", JobController, :undismiss

      # Leads (AQ-04A §8.1). `board` and `bulk` before `:id`, so they are not ids.
      get "/leads/board", LeadController, :board
      post "/leads/bulk", LeadController, :bulk
      post "/leads", LeadController, :create
      get "/leads/:id", LeadController, :show
      patch "/leads/:id", LeadController, :update
      post "/leads/:id/apply", LeadController, :apply
      post "/leads/:id/apply-again", LeadController, :apply_again
      post "/leads/:id/move", LeadController, :move
      post "/leads/:id/hold", LeadController, :hold
      post "/leads/:id/resume", LeadController, :resume
      post "/leads/:id/finish", LeadController, :finish
      post "/leads/:id/reopen", LeadController, :reopen
      post "/leads/:id/archive", LeadController, :archive
      post "/leads/:id/unarchive", LeadController, :unarchive
      post "/leads/:id/pin", LeadController, :pin
      post "/leads/:id/unpin", LeadController, :unpin
      post "/leads/:id/assign", LeadController, :assign
      post "/leads/:id/cv", LeadController, :cv
      post "/leads/:id/pipeline", LeadController, :pipeline

      # The lead page, the Tracker, retention (AQ-04B §8.1).
      get "/leads/:id/history", LeadController, :history
      post "/leads/:id/follow-up", LeadController, :follow_up
      put "/leads/:id/labels", LeadController, :labels
      get "/leads/:id/notes", LeadNoteController, :index
      post "/leads/:id/notes", LeadNoteController, :create
      patch "/lead-notes/:id", LeadNoteController, :update
      delete "/lead-notes/:id", LeadNoteController, :delete

      get "/labels", LabelController, :index
      post "/labels", LabelController, :create
      patch "/labels/:id", LabelController, :update
      delete "/labels/:id", LabelController, :delete

      get "/tracker", TrackerController, :index
      get "/tracker.csv", TrackerController, :csv

      get "/saved-views", SavedViewController, :index
      post "/saved-views", SavedViewController, :create
      patch "/saved-views/:id", SavedViewController, :update
      delete "/saved-views/:id", SavedViewController, :delete

      get "/retention/preview", RetentionController, :preview

      get "/pipelines", PipelineController, :index
      get "/pipelines/:key", PipelineController, :show
      put "/pipelines/:key", PipelineController, :update

      # Share links (AQ-03B §5.1).
      post "/tasks/:id/share-links", ShareLinkController, :create_for_task
      get "/tasks/:id/share-links", ShareLinkController, :index_for_task
      post "/jobs/:id/share-links", ShareLinkController, :create_for_job
      get "/jobs/:id/share-links", ShareLinkController, :index_for_job
      post "/leads/:id/share-links", ShareLinkController, :create_for_lead
      get "/leads/:id/share-links", ShareLinkController, :index_for_lead
      post "/share-links/:id/revoke", ShareLinkController, :revoke
      get "/shared/:token", ShareLinkController, :show

      get "/companies", CompanyController, :index
      post "/companies", CompanyController, :create
      get "/companies/:id", CompanyController, :show
      patch "/companies/:id", CompanyController, :update

      # Contacts (AQ-06 §6). `match` before `:id`, so it is not an id.
      get "/contacts", ContactController, :index
      post "/contacts/match", ContactController, :match
      post "/contacts", ContactController, :create
      get "/contacts/:id", ContactController, :show
      patch "/contacts/:id", ContactController, :update
      post "/contacts/:id/handles", ContactController, :add_handle
      post "/contacts/:id/merge", ContactController, :merge
      get "/contacts/:id/conversations", ContactController, :conversations
      get "/contacts/:id/meetings", ContactController, :meetings
      delete "/contact-handles/:id", ContactController, :remove_handle
      post "/leads/:id/contacts", ContactController, :link_lead
      delete "/leads/:id/contacts/:contact_id", ContactController, :unlink_lead

      # Conversations, messages, `.eml`, triage (AQ-06 §7).
      get "/leads/:id/conversations", ConversationController, :for_lead
      get "/conversations/:id", ConversationController, :show
      post "/messages", ConversationController, :create_message
      patch "/messages/:id", ConversationController, :update_message
      delete "/messages/:id", ConversationController, :delete_message
      post "/messages/:id/classify", ConversationController, :classify
      post "/eml", ConversationController, :eml
      get "/triage", ConversationController, :triage
      post "/conversations/:id/link", ConversationController, :link
      post "/conversations/:id/ignore", ConversationController, :ignore
      post "/conversations/:id/unignore", ConversationController, :unignore
      post "/conversations/:id/create-lead", ConversationController, :create_lead
      post "/conversations/:id/recruiter", ConversationController, :recruiter

      # Meetings (AQ-06 §8). `clash` before `:id`, so it is not an id.
      get "/meetings", MeetingController, :index
      post "/meetings/clash", MeetingController, :clash
      get "/leads/:id/meetings", MeetingController, :for_lead
      post "/leads/:id/meetings", MeetingController, :create
      get "/meetings/:id", MeetingController, :show
      patch "/meetings/:id", MeetingController, :update
      post "/meetings/:id/reschedule", MeetingController, :reschedule
      post "/meetings/:id/cancel", MeetingController, :cancel
      post "/meetings/:id/done", MeetingController, :done
      post "/meetings/:id/no-show", MeetingController, :no_show
      post "/meetings/:id/confirm", MeetingController, :confirm
      post "/meetings/:id/dismiss", MeetingController, :dismiss
      get "/meetings/:id/ics", MeetingController, :ics

      # Approvals (AQ-07 §11.1). `count` before `:id`, so it is not an id.
      get "/approvals", ApprovalController, :index
      get "/approvals/count", ApprovalController, :count
      post "/approvals", ApprovalController, :create
      get "/approvals/:id", ApprovalController, :show
      patch "/approvals/:id", ApprovalController, :update
      post "/approvals/:id/submit", ApprovalController, :submit
      post "/approvals/:id/withdraw", ApprovalController, :withdraw
      post "/approvals/:id/decide", ApprovalController, :decide
      post "/approvals/:id/revise", ApprovalController, :revise
      post "/approvals/:id/sent", ApprovalController, :sent
      get "/approvals/:id/comments", ApprovalController, :comments
      post "/approvals/:id/comments", ApprovalController, :comment
      delete "/approval-comments/:id", ApprovalController, :delete_comment
      get "/leads/:id/approvals", ApprovalController, :for_lead
      get "/customers/:id/approval-policies", ApprovalController, :policies
      put "/customers/:id/approval-policies/:kind", ApprovalController, :put_policy
      delete "/customers/:id/approval-policies/:kind", ApprovalController, :delete_policy

      # The extension (AQ-05 §11.2): connect codes, devices, Settings ›
      # Extension. `connect-codes` before `:id`, so it is not an id.
      post "/devices/connect-codes", DeviceController, :connect_code
      get "/devices", DeviceController, :index
      delete "/devices/:id", DeviceController, :delete
      get "/extension/health", ExtensionController, :health
      get "/extension/configs", ExtensionController, :configs

      # Delivery health (AQ-08 §9): the system admin's Settings › System.
      get "/deliveries/health", DeliveryController, :health

      # A person's own stages (QP2-10); the rest of `/me` is shared.
      get "/me/stages", StageController, :index
      post "/me/stages", StageController, :create
      put "/me/stages/order", StageController, :order
      patch "/me/stages/:id", StageController, :update
      delete "/me/stages/:id", StageController, :delete
    end
  end

  # **The dev clock** (AQ-04B §7.6, QP4b-1), where the console calls it:
  # compiled in only with `config :api, dev_routes: true` (dev.exs), so a
  # release has neither route. `Api.Router` mounts the same at `/dev/…`.
  if Application.compile_env(:api, :dev_routes, false) do
    scope "/v1/dev", ApiTeam do
      pipe_through [:api, :aq_shared, :aq_authenticated]

      get "/clock", DevController, :clock
      post "/clock", DevController, :set_clock
      post "/sweeps", DevController, :sweeps
    end
  end

  # Last, so it never swallows a route above it.
  ApiShared.Routes.not_found_routes()
end
