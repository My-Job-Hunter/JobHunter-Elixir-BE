defmodule Data.Contacts.HandleTest do
  @moduledoc "AQ-06 §5.1, QP6-3: a handle's normalised value, one rule per kind."

  use ExUnit.Case, async: true

  alias Data.Contacts.Handle

  doctest Handle

  test "each kind's rule, and the refusals" do
    assert Handle.normalize(:upwork, "https://www.upwork.com/freelancers/~01AA00BB11CC22DD33") ==
             {:ok, "upwork:~01aa00bb11cc22dd33"}

    assert Handle.normalize(:upwork, "Acme Labs (client)") == {:ok, "acme labs (client)"}
    assert Handle.normalize("other", " Telegram: @mei ") == {:ok, "telegram: @mei"}
    assert Handle.normalize(:email, "not-an-email") == {:error, "is not an email address"}

    assert Handle.normalize(:linkedin, "https://example.com/mei") ==
             {:error, "is not a LinkedIn profile link"}

    assert Handle.normalize(:phone, "12-34") == {:error, "is not a phone number"}
    assert Handle.normalize("fax", "1") == {:error, "is not a kind of handle"}
    assert Handle.normalize(:email, "  ") == {:error, "can't be blank"}
  end
end
