defmodule Utils.ChannelKey do
  @moduledoc """
  A platform account's link to its **identity key** (AQ-05 §8, QP5-8), pure:
  every way of writing one account gives one key, so a channel is found from
  the profile link the extension read off the page, and one account belongs
  to one person (`channels.identity_key`, unique per kind among live
  channels).

  A link is trimmed and given `https://` when it has no scheme; its host is
  lowercased and loses `www.` (or a country prefix such as `pk.`); the query
  and the fragment go. Then:

  | Handle | Key |
  |---|---|
  | `https://www.linkedin.com/in/tanweer/`, `linkedin.com/in/Tanweer?trk=x`, `/in/tanweer/overlay/…` | `linkedin:tanweer` |
  | `https://www.upwork.com/freelancers/~01aa00bb11cc22dd33`, `…/freelancers/~01AA00BB11CC22DD33?viewMode=1` | `upwork:~01aa00bb11cc22dd33` |
  | an email, a site the rules don't know | `nil` |

  A LinkedIn slug is percent-decoded and lowercased; an Upwork id keeps its
  `~` and is lowercased. `key/2` also asks that the link is the kind's own
  platform: a LinkedIn link on an Upwork channel has no key.
  `Utils.ChannelKeyTest` holds every form.
  """

  @linkedin_hosts ~w(linkedin.com)
  @upwork_hosts ~w(upwork.com)

  @doc """
  The identity key of an account's link, or `nil`.

      iex> Utils.ChannelKey.key("https://www.linkedin.com/in/tanweer/")
      "linkedin:tanweer"
      iex> Utils.ChannelKey.key("https://www.upwork.com/freelancers/~01AA00BB11CC22DD33?viewMode=1")
      "upwork:~01aa00bb11cc22dd33"
      iex> Utils.ChannelKey.key("tanweer@example.com")
      nil
  """
  @spec key(term()) :: String.t() | nil
  def key(handle) when is_binary(handle) do
    case split(String.trim(handle)) do
      {:ok, host, segments} -> rule(host, segments)
      :error -> nil
    end
  end

  def key(_handle), do: nil

  @doc """
  The key of a channel of `kind` (an atom or a string): `key/1` when the
  link is that platform's, else `nil`.

      iex> Utils.ChannelKey.key(:linkedin, "linkedin.com/in/Tanweer?trk=x")
      "linkedin:tanweer"
      iex> Utils.ChannelKey.key(:upwork, "https://www.linkedin.com/in/tanweer/")
      nil
      iex> Utils.ChannelKey.key(:email, "tanweer@example.com")
      nil
  """
  @spec key(atom() | String.t() | nil, term()) :: String.t() | nil
  def key(kind, handle) when is_atom(kind) and not is_nil(kind),
    do: key(Atom.to_string(kind), handle)

  def key(kind, handle) when kind in ["linkedin", "upwork"] do
    case key(handle) do
      nil -> nil
      key -> if String.starts_with?(key, kind <> ":"), do: key, else: nil
    end
  end

  def key(_kind, _handle), do: nil

  @doc """
  The platform a key names (`"linkedin"`, `"upwork"`), or `nil`.

      iex> Utils.ChannelKey.platform("upwork:~01aa")
      "upwork"
  """
  @spec platform(String.t() | nil) :: String.t() | nil
  def platform(key) when is_binary(key) do
    case String.split(key, ":", parts: 2) do
      [platform, _id] -> platform
      _other -> nil
    end
  end

  def platform(_key), do: nil

  # ── Rules ───────────────────────────────────────────────────────────────────

  defp rule(host, ["in", slug | _rest]) when host in @linkedin_hosts do
    case slug |> URI.decode() |> String.trim() |> String.downcase() do
      "" -> nil
      slug -> if valid_slug?(slug), do: "linkedin:" <> slug, else: nil
    end
  end

  defp rule(host, ["freelancers", "~" <> id | _rest]) when host in @upwork_hosts do
    id = String.downcase(id)
    if id =~ ~r/^[0-9a-z]{6,40}$/, do: "upwork:~" <> id, else: nil
  end

  defp rule(_host, _segments), do: nil

  defp valid_slug?(slug), do: not String.contains?(slug, ["/", "?", "#", " "])

  # The host (lowercased, without `www.` or a country prefix) and the path's
  # segments. Anything without a dotted host, an `@` before it, or a scheme
  # other than http(s) is not a link.
  defp split(link) do
    link = if link =~ ~r{^[a-zA-Z][a-zA-Z0-9+.-]*://}, do: link, else: "https://" <> link

    case URI.new(link) do
      {:ok, %URI{scheme: scheme, host: host, userinfo: nil} = uri}
      when scheme in ["http", "https"] and is_binary(host) ->
        host = host |> String.downcase() |> site_host()
        segments = (uri.path || "") |> String.split("/", trim: true)
        if String.contains?(host, "."), do: {:ok, host, segments}, else: :error

      _other ->
        :error
    end
  end

  # `www.linkedin.com`, `pk.linkedin.com` → `linkedin.com`.
  defp site_host(host) do
    Enum.find(@linkedin_hosts ++ @upwork_hosts, host, fn site ->
      host == site or String.ends_with?(host, "." <> site)
    end)
  end
end
