# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshAgent.DigestTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias AshAgent.Digest

  test "canonical JSON sorts keys and does not care how they were spelled" do
    assert Digest.jcs(%{b: 1, a: [true, nil, "x"]}) == ~s({"a":[true,null,"x"],"b":1})

    assert Digest.jcs(%{"b" => 1, "a" => [true, nil, "x"]}) ==
             Digest.jcs(%{b: 1, a: [true, nil, "x"]})
  end

  test "values with a usual string form are digested as that string" do
    assert Digest.canonical(%{on: ~D[2026-10-29], amount: Decimal.new("12.50"), kind: :edit}) ==
             %{"on" => "2026-10-29", "amount" => "12.50", "kind" => "edit"}
  end

  test "an integer JCS would round is carried as a string" do
    assert Digest.canonical(9_007_199_254_740_991) == 9_007_199_254_740_991
    assert Digest.canonical(2 ** 68) == "295147905179352825856"
  end

  test "a value with no JSON form is refused, not digested somehow" do
    assert_raise ArgumentError, fn -> Digest.jcs(%{at: {1, 2}}) end
    assert_raise ArgumentError, fn -> Digest.jcs(%URI{}) end
  end

  test "an HMAC depends on the key; a SHA-256 does not" do
    term = %{"licence_number" => "RN-1"}

    refute Digest.hmac_hex("one key", term) == Digest.hmac_hex("another key", term)
    assert Digest.sha256_hex(term) == Digest.sha256_hex(%{licence_number: "RN-1"})
    assert Digest.sha256_hex(term) =~ ~r/^[0-9a-f]{64}$/
  end
end
