defmodule Core.Accounts.DeviceTest do
  use ExUnit.Case, async: true

  alias Core.Accounts.Device

  doctest Device

  test "the families people recognise" do
    assert Device.describe(%{
             "agent" =>
               "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Safari/537.36 Edg/130.0"
           }) == "Edge on Windows"

    assert Device.describe(%{
             "agent" =>
               "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
           }) == "Safari on iOS"

    assert Device.describe(%{
             "agent" => "Mozilla/5.0 (X11; Linux x86_64; rv:120.0) Firefox/120.0"
           }) ==
             "Firefox on Linux"

    assert Device.describe(%{"agent" => "something nobody has heard of"}) ==
             "something nobody has heard of"

    assert Device.describe(nil) == nil
    assert Device.describe(%{"agent" => ""}) == nil
  end
end
