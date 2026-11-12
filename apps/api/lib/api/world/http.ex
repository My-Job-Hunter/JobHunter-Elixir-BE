defmodule Api.World.Http do
  @moduledoc """
  `mix aq.world`'s client (AQ-03B §8): JSON over `Req` to the running API,
  as one person at a time. A refusal stops the run with what the API said;
  a 429 waits as long as the API asks and tries again.

  The state `w` carries the base URL and each person's access token by
  their snapshot id (`w.tokens`), so a step says *who* did it and nothing
  else.
  """

  @doc "The answer's JSON (or `nil` for a 204), as `who` (a snapshot user id, or `nil`)."
  @spec call(map(), binary() | nil, atom(), String.t(), map() | list() | nil) :: term()
  def call(w, who, method, path, body \\ nil) do
    request(w, who, method: method, url: w.base <> path, json: body)
  end

  @doc "Puts raw bytes at an upload target (`{url, method, headers}` from `POST /media`)."
  @spec upload(map(), binary(), map(), binary()) :: term()
  def upload(w, who, %{"url" => url} = target, bytes) do
    headers = Map.to_list(target["headers"] || %{})
    method = target["method"] |> to_string() |> String.downcase() |> String.to_existing_atom()
    request(w, who, method: method, url: absolute(w, url), body: bytes, headers: headers)
  end

  @doc "Whether the server answers `GET /info` at the base URL."
  @spec up?(String.t()) :: boolean()
  def up?(base) do
    match?({:ok, %{status: 200}}, Req.get(base <> "/info", retry: false, receive_timeout: 3_000))
  rescue
    _unreachable -> false
  end

  defp absolute(w, "/" <> _path = url), do: w.base <> url
  defp absolute(_w, url), do: url

  defp request(w, who, opts, attempt \\ 1) do
    headers = [{"accept", "application/json"} | Keyword.get(opts, :headers, []) ++ auth(w, who)]

    sent =
      opts
      |> Keyword.put(:headers, headers)
      |> Keyword.put(:retry, false)
      |> Keyword.reject(fn {k, v} -> k == :json and is_nil(v) end)

    case Req.request(sent) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        if body == "", do: nil, else: body

      {:ok, %{status: 429} = response} when attempt < 5 ->
        Process.sleep(retry_after(response) * 1_000)
        request(w, who, opts, attempt + 1)

      {:ok, %{status: status, body: body}} ->
        Mix.raise("#{opts[:method]} #{opts[:url]} answered #{status}: #{inspect(body)}")

      {:error, reason} ->
        Mix.raise("#{opts[:method]} #{opts[:url]} failed: #{inspect(reason)}")
    end
  end

  defp auth(_w, nil), do: []

  defp auth(w, who) do
    case Map.fetch(w.tokens, who) do
      {:ok, token} -> [{"authorization", "Bearer " <> token}]
      :error -> Mix.raise("nobody has signed in as #{who} yet")
    end
  end

  defp retry_after(%{body: %{"error" => %{"details" => %{"retry_after_seconds" => s}}}})
       when is_integer(s),
       do: max(s, 1)

  defp retry_after(_response), do: 61
end
