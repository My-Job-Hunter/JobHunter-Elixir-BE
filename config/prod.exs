import Config

# Compile-time production defaults; everything a server decides is in
# runtime.exs, so one build serves every environment.

# Raise per host with LOG_LEVEL (runtime.exs), no rebuild.
config :logger, level: :info

# No in-memory mailbox in a release: mail goes through the provider P7
# configures in runtime.exs, or nowhere.
config :swoosh, local: false
