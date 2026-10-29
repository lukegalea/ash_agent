# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshAgent.DigestKey do
  @moduledoc """
  The secret an invocation's `args_digest` is keyed with. The host implements it.

  `args_digest` is an HMAC-SHA256 of the canonical JSON of the arguments
  (`AshAgent.Digest.hmac_hex/2`), so two requests with one key can be compared without
  storing the arguments in a form anyone could reverse by guessing. The key is the host's:
  a host that seals content under per-subject keys can derive it from the key the row's
  content is sealed under, so destroying that key also leaves the digest unrecomputable.

  The package calls `digest_key/1` with the row, as stored or as it is about to be
  inserted (after every change of the request has run), and with no transaction of its
  own open.
  """

  @doc "The HMAC key for `invocation`'s argument digest."
  @callback digest_key(invocation :: Ash.Resource.record()) :: {:ok, binary()} | {:error, term()}
end
