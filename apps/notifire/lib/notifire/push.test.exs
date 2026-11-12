defmodule Notifire.PushTest do
  @moduledoc """
  Web Push (AQ-08 §7.6, QP8-13, §13 step 8): the payload encrypted for the
  browser (RFC 8291) and decrypted here by an independent HKDF, the VAPID
  token signed for the push service's origin (RFC 8292) and verified with
  the public key, and against a local stand-in endpoint (`Req.Test`): a
  404 or 410 removes that browser, another refusal marks it and counts as a
  failure, none left means no target. Never the network.
  """

  use Notifire.NotifireCase, async: true

  alias Data.Notifications.{Delivery, PushSubscription}
  alias Notifire.Delivery, as: Sweep
  alias Notifire.Push

  @moduletag :capture_log

  @now ~U[2026-11-12 06:00:00.000000Z]
  @send [push: [send: true]]

  defp hkdf(salt, ikm, info, length) do
    prk = :crypto.mac(:hmac, :sha256, salt, ikm)
    binary_part(:crypto.mac(:hmac, :sha256, prk, info <> <<1>>), 0, length)
  end

  test "the payload decrypts with the browser's private key and auth secret (RFC 8291)" do
    {ua_public, ua_private} = :crypto.generate_key(:ecdh, :prime256v1)
    auth = :crypto.strong_rand_bytes(16)
    payload = ~s({"title":"Push works. AutoQare can reach this browser."})

    assert {:ok, record} = Push.encrypt(payload, ua_public, auth)

    <<salt::binary-16, 4096::unsigned-big-32, 65::8, as_public::binary-65, rest::binary>> = record
    shared = :crypto.compute_key(:ecdh, as_public, ua_private, :prime256v1)
    ikm = hkdf(auth, shared, "WebPush: info" <> <<0>> <> ua_public <> as_public, 32)
    cek = hkdf(salt, ikm, "Content-Encoding: aes128gcm" <> <<0>>, 16)
    nonce = hkdf(salt, ikm, "Content-Encoding: nonce" <> <<0>>, 12)

    size = byte_size(rest) - 16
    <<cipher::binary-size(^size), tag::binary-16>> = rest

    assert :crypto.crypto_one_time_aead(:aes_128_gcm, cek, nonce, cipher, <<>>, tag, false) ==
             payload <> <<2>>
  end

  test "a browser key that isn't a P-256 point is a refusal, not a crash" do
    assert {:error, {:encrypt, _why}} = Push.encrypt("x", "not a key", "secret")
  end

  describe "against a stand-in endpoint" do
    setup do
      org = organisation_fixture()
      fiza = user_fixture(display_name: "Fiza")
      test = self()

      Req.Test.stub(Push, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test, {:pushed, conn.request_path, Map.new(conn.req_headers), body})

        status =
          case conn.request_path do
            "/gone" -> 410
            "/missing" -> 404
            "/broken" -> 500
            _ok -> 201
          end

        Plug.Conn.send_resp(conn, status, "")
      end)

      %{org: org, fiza: fiza}
    end

    defp push_row(c) do
      n =
        notification_fixture(c.org, c.fiza,
          notification_kind_key: "tasks.assigned",
          title: "Hira gave you “Fix the CV”"
        )

      delivery_fixture(n, channel: :push, deliver_after: @now)
    end

    test "encrypted, signed for the service's origin, a day to live, urgent", c do
      sub = push_subscription_fixture(c.fiza, endpoint: "https://push.example/ok")
      row = push_row(c)

      assert Sweep.run(@now, @send) == %{sent: 1, skipped: 0, failed: 0}
      assert %{state: :sent} = Repo.get!(Delivery, row.id)
      assert %{last_used_at: %DateTime{}, failed_at: nil} = Repo.get!(PushSubscription, sub.id)

      assert_received {:pushed, "/ok", headers, body}
      assert headers["ttl"] == "86400"
      assert headers["urgency"] == "high"
      # (`content-encoding: aes128gcm` is sent; Req's test adapter strips it
      # before the stand-in sees the request, so the record is checked above.)
      assert byte_size(body) > 86

      "vapid t=" <> rest = headers["authorization"]
      [jwt, "k=" <> public_key] = String.split(rest, ", ")
      vapid = Application.fetch_env!(:notifire, :web_push)
      assert public_key == vapid[:public_key]

      [h, claims, sig] = String.split(jwt, ".")
      claims = claims |> Base.url_decode64!(padding: false) |> Jason.decode!()
      assert claims["aud"] == "https://push.example"
      assert claims["sub"] == "mailto:support@autoqare.com"
      assert claims["exp"] > System.os_time(:second)

      <<r::binary-32, s::binary-32>> = Base.url_decode64!(sig, padding: false)

      der =
        :public_key.der_encode(
          :"ECDSA-Sig-Value",
          {:"ECDSA-Sig-Value", :binary.decode_unsigned(r), :binary.decode_unsigned(s)}
        )

      key = Base.url_decode64!(public_key, padding: false)
      signed = h <> "." <> Enum.at(String.split(jwt, "."), 1)
      assert :crypto.verify(:ecdsa, :sha256, signed, der, [key, :prime256v1])
    end

    test "a 404 or 410 removes that browser; the row is sent if another took it", c do
      push_subscription_fixture(c.fiza, endpoint: "https://push.example/gone")
      push_subscription_fixture(c.fiza, endpoint: "https://push.example/ok")
      row = push_row(c)

      assert Sweep.run(@now, @send) == %{sent: 1, skipped: 0, failed: 0}
      assert %{state: :sent} = Repo.get!(Delivery, row.id)
      assert [%{endpoint: "https://push.example/ok"}] = Repo.all(PushSubscription)
    end

    test "every browser gone: removed, and the row has no target", c do
      push_subscription_fixture(c.fiza, endpoint: "https://push.example/gone")
      push_subscription_fixture(c.fiza, endpoint: "https://push.example/missing")
      row = push_row(c)

      assert Sweep.run(@now, @send) == %{sent: 0, skipped: 1, failed: 0}
      assert %{state: :skipped, skip_reason: :no_target} = Repo.get!(Delivery, row.id)
      assert Repo.all(PushSubscription) == []
    end

    test "browsers left but every one refusing is a failure: the browser marked, the row retried",
         c do
      sub = push_subscription_fixture(c.fiza, endpoint: "https://push.example/broken")
      row = push_row(c)

      assert Sweep.run(@now, @send) == %{sent: 0, skipped: 0, failed: 1}

      assert %{state: :pending, attempts: 1, error: "push refused: 500"} =
               Repo.get!(Delivery, row.id)

      assert %{failed_at: %DateTime{}} = Repo.get!(PushSubscription, sub.id)
    end
  end
end
