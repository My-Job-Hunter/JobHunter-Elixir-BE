defmodule Core.Auth.GoogleTest do
  @moduledoc """
  Google's token, verified against the tests' own keys; and the dev stand-in,
  switched on for the tests that need it. `async: false` because the stand-in
  tests swap global config.
  """

  use ExUnit.Case, async: false

  alias Core.Auth.Google
  alias Core.Auth.GoogleTestKeys, as: Keys

  @now ~U[2026-11-09 10:00:00Z]

  describe "a real token" do
    test "is believed when every check passes" do
      token = Keys.token("fiza@example.com", %{"exp" => DateTime.to_unix(@now) + 60})

      assert {:ok,
              %{
                subject: "google-sub-fiza@example.com",
                email: "fiza@example.com",
                name: "Google Person"
              }} =
               Google.verify(token, @now)
    end

    test "the address is lowered and a blank name is nil" do
      token = Keys.token("Fiza@Example.com", %{"name" => "  "})
      assert {:ok, %{email: "fiza@example.com", name: nil}} = Google.verify(token, @now)
    end

    test "one answer for every failure" do
      good = %{"exp" => DateTime.to_unix(@now) + 60}

      for bad <- [
            %{"aud" => "somebody-else"},
            %{"iss" => "https://evil.example"},
            %{"exp" => DateTime.to_unix(@now) - 1},
            %{"email_verified" => false},
            %{"kid" => "unknown-key"}
          ] do
        token = Keys.token("fiza@example.com", Map.merge(good, bad))
        assert Google.verify(token, @now) == {:error, :invalid_google_token}, inspect(bad)
      end

      assert Google.verify("not.a.jwt", @now) == {:error, :invalid_google_token}
      assert Google.verify("", @now) == {:error, :invalid_google_token}
      assert Google.verify(nil, @now) == {:error, :invalid_google_token}
    end

    test "a dev stand-in token is refused while the stand-in is off" do
      assert Google.verify("dev:fiza@example.com", @now) == {:error, :invalid_google_token}
      refute Google.stand_in?()
    end
  end

  describe "the dev stand-in" do
    setup do
      original = Application.get_env(:core, :google)
      Application.put_env(:core, :google, Keyword.merge(original, client_id: nil, stand_in: true))
      on_exit(fn -> Application.put_env(:core, :google, original) end)
      :ok
    end

    test "believes dev:<email> and makes the subject from it" do
      assert Google.stand_in?()

      assert Google.verify("dev:Fiza@Example.com", @now) ==
               {:ok, %{subject: "dev:fiza@example.com", email: "fiza@example.com", name: nil}}
    end

    test "still wants an address" do
      assert Google.verify("dev:not-an-address", @now) == {:error, :invalid_google_token}
    end

    test "settings say so" do
      assert Google.settings() == %{client_id: nil, stand_in: true}
    end

    test "a client id turns it off" do
      Application.put_env(
        :core,
        :google,
        Keyword.put(Application.get_env(:core, :google), :client_id, "x")
      )

      refute Google.stand_in?()
    end
  end
end
