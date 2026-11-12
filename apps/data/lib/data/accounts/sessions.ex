defmodule Data.Accounts.Sessions do
  @moduledoc """
  A person's sessions (AQ-01 §6.1 `/me/sessions`): one per sign-in, read
  from the refresh tokens `guardian_tokens` holds. Each sign-in mints a
  session id (`sid`) that both tokens carry and a refresh keeps, so a device
  stays one row across refreshes and can be signed out on its own.
  """

  import Ecto.Query, warn: false

  alias Data.Repo

  @doc """
  The live sessions, newest first: the id, the device, when it signed in,
  when it lapses. An extension's (`dev.app` `ext`, AQ-05 §11.2) is a device
  now, listed under Account › Extension, so it is left out.
  """
  @spec list_sessions(binary(), DateTime.t()) :: [map()]
  def list_sessions(user_id, %DateTime{} = now) do
    sub = to_string(user_id)
    epoch = DateTime.to_unix(now)

    from(t in "guardian_tokens",
      where: t.sub == ^sub and t.typ == "refresh" and t.exp > ^epoch,
      order_by: [desc: t.inserted_at],
      select: %{
        sid: fragment("? ->> 'sid'", t.claims),
        device: fragment("? -> 'dev'", t.claims),
        signed_in_at: t.inserted_at,
        expires_at: t.exp
      }
    )
    |> Repo.all()
    |> Enum.filter(&(&1.sid && not extension?(&1.device)))
    |> Enum.uniq_by(& &1.sid)
    |> Enum.map(&%{&1 | expires_at: DateTime.from_unix!(&1.expires_at)})
  end

  defp extension?(%{"app" => "ext"}), do: true
  defp extension?(_device), do: false

  @doc "Ends one session: every token carrying its id. Answers how many rows went."
  @spec revoke_session(binary(), String.t()) :: non_neg_integer()
  def revoke_session(user_id, sid) when is_binary(sid) do
    sub = to_string(user_id)

    {n, _rows} =
      from(t in "guardian_tokens",
        where: t.sub == ^sub and fragment("? ->> 'sid'", t.claims) == ^sid
      )
      |> Repo.delete_all()

    n
  end
end
