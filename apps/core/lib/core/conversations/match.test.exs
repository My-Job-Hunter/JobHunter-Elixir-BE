defmodule Core.Conversations.MatchTest do
  @moduledoc "The pure part of AQ-09 §7's rules; each rule end to end is `Core.InboundTest`'s."

  use ExUnit.Case, async: true

  alias Core.Conversations.Match

  doctest Match

  test "a channel's single profile narrows; several or none don't" do
    assert Match.profile_id(%{profile_channels: [%{profile_id: "p1"}]}) == "p1"

    assert Match.profile_id(%{profile_channels: [%{profile_id: "p1"}, %{profile_id: "p2"}]}) ==
             nil

    assert Match.profile_id(nil) == nil
    assert Match.profiles(nil) == []
  end
end
