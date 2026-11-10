# Intentionally empty.
#
# `test_paths: ["test", "lib"]` co-locates unit tests beside their source, and
# Mix requires a helper in *every* test path. The real one is
# `test/test_helper.exs`; this exists only to satisfy that lookup, and calling
# `ExUnit.start/0` twice from two helpers is what it is here to avoid.
