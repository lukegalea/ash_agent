# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshAgent.Digest do
  @moduledoc """
  Digests of invocation content that do not depend on how a value was spelled.

  Every digest is taken over RFC 8785 (JCS) canonical JSON, so two maps with the same
  entries give the same bytes whatever their key order and whether their keys were atoms
  or strings.

    * `sha256_hex/1` is for digests shown outside the application, such as a target's
      digest: anyone holding the same declaration can recompute it.
    * `hmac_hex/2` is for digests of arguments. Arguments are often guessable (a
      clinician id, a yes or no), so a plain hash of them could be reversed by trying
      candidates; a keyed HMAC cannot be without the key. The key comes from the host
      (`AshAgent.DigestKey`).

  ## What `canonical/1` accepts

  Maps, lists, strings, booleans, `nil`, integers and floats, as JSON has them. Atoms
  other than `true`, `false` and `nil` become strings, and so do map keys. `Decimal`,
  `Date`, `Time`, `NaiveDateTime` and `DateTime` become their usual string forms.

  JCS reads every number as an IEEE-754 double, so an integer beyond ±2^53 would be
  rounded by any other JCS implementation and not by this one. Such an integer is
  written as a decimal string instead (RFC 8785 Appendix D), so the digest stays
  reproducible. Anything else, another struct or a tuple, raises `ArgumentError`
  rather than being digested in some unstated form.
  """

  @max_safe_integer 9_007_199_254_740_991

  @doc "`term` as JSON data with string keys, ready for canonical encoding."
  @spec canonical(term()) :: term()
  def canonical(term)

  def canonical(nil), do: nil
  def canonical(boolean) when is_boolean(boolean), do: boolean
  def canonical(string) when is_binary(string), do: string
  def canonical(float) when is_float(float), do: float

  def canonical(integer) when is_integer(integer) and abs(integer) <= @max_safe_integer,
    do: integer

  def canonical(integer) when is_integer(integer), do: Integer.to_string(integer)
  def canonical(atom) when is_atom(atom), do: Atom.to_string(atom)
  def canonical(%Decimal{} = decimal), do: Decimal.to_string(decimal, :normal)
  def canonical(%Date{} = date), do: Date.to_iso8601(date)
  def canonical(%Time{} = time), do: Time.to_iso8601(time)
  def canonical(%NaiveDateTime{} = datetime), do: NaiveDateTime.to_iso8601(datetime)
  def canonical(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  def canonical(list) when is_list(list), do: Enum.map(list, &canonical/1)

  def canonical(%{__struct__: struct}) do
    raise ArgumentError, "cannot digest a #{inspect(struct)}; pass its JSON form instead"
  end

  def canonical(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {key_string(key), canonical(value)} end)

  def canonical(other),
    do: raise(ArgumentError, "cannot digest #{inspect(other)}; it has no JSON form")

  @doc "The RFC 8785 canonical JSON bytes of `term`."
  @spec jcs(term()) :: binary()
  def jcs(term), do: term |> canonical() |> Jcs.encode()

  @doc "SHA-256 of the canonical JSON of `term`, as lowercase hex."
  @spec sha256_hex(term()) :: String.t()
  def sha256_hex(term), do: :crypto.hash(:sha256, jcs(term)) |> Base.encode16(case: :lower)

  @doc "HMAC-SHA256 of the canonical JSON of `term` under `key`, as lowercase hex."
  @spec hmac_hex(binary(), term()) :: String.t()
  def hmac_hex(key, term) when is_binary(key) and byte_size(key) > 0,
    do: :crypto.mac(:hmac, :sha256, key, jcs(term)) |> Base.encode16(case: :lower)

  defp key_string(key) when is_binary(key), do: key
  defp key_string(key) when is_atom(key), do: Atom.to_string(key)

  defp key_string(key),
    do: raise(ArgumentError, "cannot digest a map keyed by #{inspect(key)}")
end
