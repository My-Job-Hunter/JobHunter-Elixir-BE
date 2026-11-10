# Used by "mix format"
#
# **`subdirectories` is what makes `mix format` at the root reach the apps**,
# and each app's own `.formatter.exs` decides what it covers. This file covers
# only what sits above them.
[
  inputs: ["{mix,.formatter}.exs", "config/*.exs"],
  subdirectories: ["apps/*"]
]
