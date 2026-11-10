# Used by "mix format"
#
# `import_deps: [:phoenix]` is what teaches the formatter Phoenix's own macros
# — without it `plug`, `pipeline` and the router's verbs get parenthesised.
#
# **`priv` is in the list, and it is easy to leave out.** The generated file
# covers `config`, `lib` and `test` only, which silently excludes everything
# under `priv`.
[
  import_deps: [:phoenix],
  inputs: ["{mix,.formatter}.exs", "{config,lib,priv,test}/**/*.{ex,exs}"]
]
