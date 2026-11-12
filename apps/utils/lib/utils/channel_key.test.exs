defmodule Utils.ChannelKeyTest do
  @moduledoc "AQ-05 §8's table, a test per form."

  use ExUnit.Case, async: true

  alias Utils.ChannelKey

  doctest ChannelKey

  describe "LinkedIn: linkedin:{slug}" do
    for handle <- [
          "https://www.linkedin.com/in/tanweer/",
          "https://www.linkedin.com/in/tanweer",
          "linkedin.com/in/Tanweer?trk=x",
          "www.linkedin.com/in/TANWEER/",
          "https://www.linkedin.com/in/tanweer/overlay/contact-info/",
          "https://www.linkedin.com/in/tanweer/details/experience/?x=1#top",
          "http://linkedin.com/in/tanweer",
          "https://pk.linkedin.com/in/tanweer",
          "  https://www.linkedin.com/in/tanweer/  "
        ] do
      test "#{handle}" do
        assert ChannelKey.key(unquote(handle)) == "linkedin:tanweer"
      end
    end

    test "a slug with a hyphen and digits keeps them" do
      assert ChannelKey.key("https://www.linkedin.com/in/naveed-example/") ==
               "linkedin:naveed-example"

      assert ChannelKey.key("https://www.linkedin.com/in/fiza-malik-1a2b3c") ==
               "linkedin:fiza-malik-1a2b3c"
    end

    test "a percent-encoded slug is decoded and lowercased" do
      assert ChannelKey.key("https://www.linkedin.com/in/Jos%C3%A9-p") == "linkedin:josé-p"
    end

    test "a LinkedIn page that is not a person has no key" do
      assert ChannelKey.key("https://www.linkedin.com/company/bamboo-invest/") == nil
      assert ChannelKey.key("https://www.linkedin.com/jobs/view/4012233871") == nil
      assert ChannelKey.key("https://www.linkedin.com/in/") == nil
      assert ChannelKey.key("https://www.linkedin.com/") == nil
    end
  end

  describe "Upwork: upwork:{~id}" do
    for handle <- [
          "https://www.upwork.com/freelancers/~01aa00bb11cc22dd33",
          "https://www.upwork.com/freelancers/~01AA00BB11CC22DD33?viewMode=1",
          "upwork.com/freelancers/~01aa00bb11cc22dd33/",
          "https://www.upwork.com/freelancers/~01aa00bb11cc22dd33?mp_source=share#portfolio"
        ] do
      test "#{handle}" do
        assert ChannelKey.key(unquote(handle)) == "upwork:~01aa00bb11cc22dd33"
      end
    end

    test "a freelancer link without the ~id, or another Upwork page, has no key" do
      assert ChannelKey.key("https://www.upwork.com/freelancers/tanweer") == nil
      assert ChannelKey.key("https://www.upwork.com/jobs/~021234567890") == nil
      assert ChannelKey.key("https://www.upwork.com/freelancers/~") == nil
    end
  end

  describe "nil: an email, a site the rules don't know" do
    for handle <- [
          "tanweer@example.com",
          "mailto:tanweer@example.com",
          "https://github.com/tanweer",
          "https://www.indeed.com/in/tanweer",
          "tanweer",
          "",
          "   ",
          "ftp://www.linkedin.com/in/tanweer",
          "https://user@www.linkedin.com/in/tanweer"
        ] do
      test "#{inspect(handle)}" do
        assert ChannelKey.key(unquote(handle)) == nil
      end
    end

    test "nothing at all" do
      assert ChannelKey.key(nil) == nil
      assert ChannelKey.key(42) == nil
    end
  end

  describe "key/2: the link must be the kind's own platform" do
    test "a LinkedIn channel's LinkedIn link" do
      assert ChannelKey.key(:linkedin, "https://www.linkedin.com/in/tanweer/") ==
               "linkedin:tanweer"

      assert ChannelKey.key("linkedin", "linkedin.com/in/tanweer") == "linkedin:tanweer"
    end

    test "an Upwork channel's Upwork link" do
      assert ChannelKey.key(:upwork, "https://www.upwork.com/freelancers/~01aa00bb11cc22dd33") ==
               "upwork:~01aa00bb11cc22dd33"
    end

    test "a link of another platform, or a kind without rules, has no key" do
      assert ChannelKey.key(:linkedin, "https://www.upwork.com/freelancers/~01aa00bb11cc22dd33") ==
               nil

      assert ChannelKey.key(:email, "https://www.linkedin.com/in/tanweer/") == nil
      assert ChannelKey.key(:indeed, "https://www.linkedin.com/in/tanweer/") == nil
      assert ChannelKey.key(nil, "https://www.linkedin.com/in/tanweer/") == nil
    end
  end

  test "platform/1 names the key's platform" do
    assert ChannelKey.platform("linkedin:tanweer") == "linkedin"
    assert ChannelKey.platform(nil) == nil
    assert ChannelKey.platform("nonsense") == nil
  end
end
