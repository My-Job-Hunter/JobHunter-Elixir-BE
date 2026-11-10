# Used by "mix format"
#
# **`priv` is in the list, and it is easy to leave out.** The generated
# `.formatter.exs` covers `config`, `lib` and `test` only — which silently
# excludes every migration, and a migration is the one kind of file nobody
# re-reads after it is written.
[
  inputs: ["{mix,.formatter}.exs", "{config,lib,priv,test}/**/*.{ex,exs}"]
]
