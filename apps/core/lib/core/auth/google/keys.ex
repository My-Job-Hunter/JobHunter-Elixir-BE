defmodule Core.Auth.Google.Keys do
  @moduledoc """
  Where Google's signing keys come from: a behaviour, so a test supplies its
  own keys instead of Google's (`config :core, :google, keys:`).
  """

  @callback fetch() :: {:ok, %{String.t() => JOSE.JWK.t()}} | {:error, term()}
end

defmodule Core.Auth.Google.Keys.Google do
  @moduledoc """
  Google's published signing keys, by key id, from its JWKS endpoint, through
  `Req` (the house HTTP client). **Cached for as long as Google says**
  (`Cache-Control: max-age`, an hour when it says nothing).
  """

  @behaviour Core.Auth.Google.Keys

  @url "https://www.googleapis.com/oauth2/v3/certs"
  @default_max_age_s 3600

  @impl true
  def fetch do
    now = System.system_time(:second)

    case :persistent_term.get({__MODULE__, :keys}, nil) do
      {keys, expires_at} when expires_at > now -> {:ok, keys}
      _missing_or_stale -> refresh(now)
    end
  end

  defp refresh(now) do
    case Req.get(@url, retry: false) do
      {:ok, %{status: 200, body: %{"keys" => keys}} = response} ->
        parsed = Map.new(keys, &{&1["kid"], JOSE.JWK.from_map(&1)})
        :persistent_term.put({__MODULE__, :keys}, {parsed, now + max_age(response)})
        {:ok, parsed}

      {:ok, response} ->
        {:error, {:unexpected_status, response.status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp max_age(response) do
    with [value | _rest] <- Req.Response.get_header(response, "cache-control"),
         [_whole, seconds] <- Regex.run(~r/max-age=(\d+)/, value) do
      String.to_integer(seconds)
    else
      _none -> @default_max_age_s
    end
  end
end
