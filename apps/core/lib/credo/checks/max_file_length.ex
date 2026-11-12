if Code.ensure_loaded?(Credo.Check) do
  defmodule Credo.Check.Readability.MaxFileLength do
    @moduledoc """
    Caps a source file's length.

    Set to **500** (copied from mCart). A 1000-line context is a context
    that should have been two, and nobody notices it happening because it
    grows fifty lines at a time.

    The `Code.ensure_loaded?` guard matters: Credo is a `:dev, :test`
    dependency, so without it this module fails to compile in production.

    ## `excluded`, and it is meant to stay short

    A list of path fragments the cap does not apply to. **Adding one is a
    decision**, and `.credo.exs` carries the argument beside each. It is
    empty today.

    A route table is the kind of file that may one day earn an entry: it is a
    **manifest**, and splitting a manifest to satisfy a line count scatters
    routes across files, matched in an order no single file shows.
    """

    use Credo.Check,
      base_priority: :normal,
      category: :readability,
      param_defaults: [max_length: 500, excluded: []],
      explanations: [
        check: @moduledoc,
        params: [
          max_length: "Maximum number of lines in a file.",
          excluded: "Path fragments the cap does not apply to. Argue for each in .credo.exs."
        ]
      ]

    @impl Credo.Check
    def run(%SourceFile{} = source_file, params) do
      issue_meta = IssueMeta.for(source_file, params)
      max_length = Params.get(params, :max_length, __MODULE__)
      excluded = Params.get(params, :excluded, __MODULE__)

      lines = SourceFile.lines(source_file)
      count = length(lines)

      if count > max_length and not excluded?(source_file.filename, excluded) do
        [issue_for(issue_meta, count, max_length)]
      else
        []
      end
    end

    defp excluded?(filename, excluded) do
      Enum.any?(excluded, &String.contains?(filename, &1))
    end

    defp issue_for(issue_meta, count, max_length) do
      format_issue(issue_meta,
        message: "File has #{count} lines, exceeding the maximum of #{max_length}.",
        line_no: 1
      )
    end
  end
end
