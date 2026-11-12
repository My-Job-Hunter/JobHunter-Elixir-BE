defmodule Utils.SafeUrl do
  @moduledoc """
  Link safety for content somebody else wrote (mCart's, ported): a task's
  links (AQ-02 §5.1) go through it on the way in, so the value never
  reaching storage is what keeps the next client safe without its own check.

  **An allow-list of schemes, never a block-list**: `javascript:`,
  `data:text/html`, `vbscript:` and `blob:` all execute, and a block-list is
  a promise to have thought of every scheme ever registered. Two are
  allowed; everything else is no link at all.
  """

  @allowed_schemes ~w(http https)

  @doc "The schemes a link may have."
  def allowed_schemes, do: @allowed_schemes

  @doc """
  Whether this is safe to put in an `href`: absolute, http or https, with a host.

      iex> Utils.SafeUrl.safe?("https://example.com/a")
      true
      iex> Utils.SafeUrl.safe?("javascript:alert(1)")
      false
      iex> Utils.SafeUrl.safe?("/relative/path")
      false
  """
  @spec safe?(term()) :: boolean()
  def safe?(value) when is_binary(value) do
    case URI.new(String.trim(value)) do
      {:ok, %URI{scheme: scheme, host: host}} when is_binary(host) and host != "" ->
        String.downcase(scheme || "") in @allowed_schemes

      _unparseable_or_relative ->
        false
    end
  end

  def safe?(_value), do: false

  @doc """
  The trimmed URL if it can be trusted, otherwise `nil`. **Fails closed**:
  `nil` beats `"#"`, a link that silently does nothing.

      iex> Utils.SafeUrl.sanitise("  https://example.com  ")
      "https://example.com"
      iex> Utils.SafeUrl.sanitise("data:text/html,hi")
      nil
  """
  @spec sanitise(term()) :: String.t() | nil
  def sanitise(value) do
    if safe?(value), do: String.trim(value)
  end

  @doc """
  The host without `www.`, for labelling a link by where it goes.

      iex> Utils.SafeUrl.host("https://www.linkedin.com/jobs/1")
      "linkedin.com"
  """
  @spec host(term()) :: String.t() | nil
  def host(value) do
    case sanitise(value) do
      nil -> nil
      url -> url |> URI.parse() |> Map.get(:host) |> String.replace(~r/^www\./, "")
    end
  end
end
