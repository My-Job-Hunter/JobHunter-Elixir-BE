defmodule Core.Inbound.AddressTest do
  use ExUnit.Case, async: true

  alias Data.Customers.Channel

  doctest Core.Inbound.Address

  test "a channel's token is ten characters of the address's alphabet" do
    for _n <- 1..50 do
      token = Channel.new_token()
      assert token =~ ~r/^[a-hjkmnp-z2-9]{10}$/
    end
  end
end
