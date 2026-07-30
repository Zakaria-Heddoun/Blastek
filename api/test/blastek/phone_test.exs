defmodule Blastek.PhoneTest do
  @moduledoc """
  Phone normalization (E3-T4 / F0.2).

  This module decides whether two strings are the same person, so the
  interesting tests are the equivalences: every spelling of one number must
  collapse to one string, and nothing else may collapse into it.
  """
  use ExUnit.Case, async: true

  alias Blastek.Accounts.Phone

  @canonical "+212612345678"

  describe "normalize/1 accepts the ways Moroccans actually write a number" do
    test "national with the trunk zero" do
      assert Phone.normalize("0612345678") == {:ok, @canonical}
    end

    test "already E.164" do
      assert Phone.normalize(@canonical) == {:ok, @canonical}
    end

    test "country code without the plus" do
      assert Phone.normalize("212612345678") == {:ok, @canonical}
    end

    test "international prefix 00" do
      assert Phone.normalize("00212612345678") == {:ok, @canonical}
    end

    test "country code followed by the trunk zero — a common mangling" do
      # +2120612… is wrong but widespread; repairing it beats rejecting it.
      assert Phone.normalize("+2120612345678") == {:ok, @canonical}
    end

    test "spaces, dashes, dots, slashes and parentheses" do
      for spelling <- [
            "06 12 34 56 78",
            "06-12-34-56-78",
            "06.12.34.56.78",
            "(0612) 34 56 78",
            "+212 6 12 34 56 78",
            " 0612345678 ",
            "0612/345678"
          ] do
        assert Phone.normalize(spelling) == {:ok, @canonical}, "failed on #{inspect(spelling)}"
      end
    end

    test "07 mobiles and 05 landlines" do
      assert Phone.normalize("0712345678") == {:ok, "+212712345678"}
      assert Phone.normalize("0522123456") == {:ok, "+212522123456"}
    end
  end

  describe "normalize/1 refuses what it cannot be sure about" do
    test "empty input" do
      assert Phone.normalize("") == {:error, :empty}
      assert Phone.normalize("   ") == {:error, :empty}
      assert Phone.normalize(nil) == {:error, :empty}
    end

    test "letters" do
      assert Phone.normalize("not a phone") == {:error, :not_a_number}
      assert Phone.normalize("0612345abc") == {:error, :not_a_number}
    end

    test "too short" do
      assert Phone.normalize("061234") == {:error, :wrong_length}
    end

    test "another country" do
      # A French mobile — well-formed, just not ours.
      assert Phone.normalize("+33612345678") == {:error, :unsupported_country}
      assert Phone.normalize("+1 415 555 0132") == {:error, :unsupported_country}
    end

    test "a Moroccan-length number with an impossible prefix" do
      # No Moroccan subscriber number starts with 1.
      assert Phone.normalize("0112345678") == {:error, :unsupported_country}
    end

    test "every rejection has a message fit to show a user" do
      for reason <- [:empty, :not_a_number, :wrong_length, :unsupported_country, :not_mobile] do
        message = Phone.message(reason)
        assert is_binary(message) and message != ""
        # No leaked atoms or internals in user-facing copy.
        refute message =~ ":"
      end
    end
  end

  describe "normalize_mobile/1" do
    test "accepts 06 and 07" do
      assert {:ok, _} = Phone.normalize_mobile("0612345678")
      assert {:ok, _} = Phone.normalize_mobile("0712345678")
    end

    test "rejects a landline, because an OTP would never arrive" do
      assert Phone.normalize_mobile("0522123456") == {:error, :not_mobile}
    end

    test "still reports the underlying problem when the number is malformed" do
      assert Phone.normalize_mobile("abc") == {:error, :not_a_number}
    end
  end

  describe "properties" do
    # Exhaustive over the shape that matters rather than randomly sampled: the
    # input space here is small and structured, so covering it beats sampling it.
    @subscribers for prefix <- ~w(6 7 5),
                     rest <- ["12345678", "00000000", "99999999", "01234567"],
                     do: prefix <> rest

    test "normalization is idempotent" do
      for subscriber <- @subscribers do
        {:ok, once} = Phone.normalize("0" <> subscriber)
        assert Phone.normalize(once) == {:ok, once}
      end
    end

    test "all spellings of one number agree" do
      for subscriber <- @subscribers do
        spellings = [
          "0" <> subscriber,
          "+212" <> subscriber,
          "212" <> subscriber,
          "00212" <> subscriber,
          "+2120" <> subscriber,
          "0" <> spaced(subscriber)
        ]

        results = Enum.map(spellings, &Phone.normalize/1)

        assert [single] = Enum.uniq(results),
               "spellings of #{subscriber} disagreed: #{inspect(Enum.zip(spellings, results))}"

        assert single == {:ok, "+212" <> subscriber}
      end
    end

    test "distinct numbers never collide" do
      normalized =
        for subscriber <- @subscribers do
          {:ok, canonical} = Phone.normalize("0" <> subscriber)
          canonical
        end

      assert length(Enum.uniq(normalized)) == length(@subscribers)
    end

    test "output is always E.164: a plus, 212, then nine digits" do
      for subscriber <- @subscribers do
        {:ok, canonical} = Phone.normalize("0" <> subscriber)
        assert canonical =~ ~r/^\+212\d{9}$/
      end
    end
  end

  describe "display helpers" do
    test "format_local reads the way a Moroccan would say it" do
      assert Phone.format_local(@canonical) == "06 12 34 56 78"
    end

    test "mask keeps enough to recognise, not enough to dial" do
      masked = Phone.mask(@canonical)
      assert masked == "06 •• •• 56 78"
      refute masked =~ "1234"
    end

    test "display helpers pass through anything not normalized" do
      assert Phone.format_local("") == ""
      assert Phone.mask("+33612345678") == "+33612345678"
    end
  end

  defp spaced(subscriber) do
    subscriber |> String.graphemes() |> Enum.chunk_every(2) |> Enum.map_join(" ", &Enum.join/1)
  end
end
