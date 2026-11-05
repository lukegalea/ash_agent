# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshAgent.ReleaseManifest do
  @moduledoc """
  Which release is live for a target, as far as an approval is concerned. The host
  implements it.

  A release is a set of things tested together (agents, tools, decisions and so on) that the
  host keeps and promotes as one. The package does not know what is in it. It asks only for
  the active release that covers a target in a tenant, and the digest that identifies it, so
  that:

    * a request records the active release as its `release_manifest_id`, and an approval
      binds the release's digest as `manifest_digest` in its `authorization_details`
      (`AshAgent.Invocation.Approval`);
    * an approval granted under one release does not run under another: `apply_decision` and
      every `claim` find the row `stale` with `error_code` `"manifest_changed"` when the active
      release's digest is no longer the one that was approved.

  A resource that declares no `release_manifest` in its `invocation` section binds nothing,
  and `manifest_digest` stays nil.
  """

  @typedoc "The active release: its id, and the digest an approval binds."
  @type active :: %{required(:id) => Ash.UUID.t(), required(:digest) => String.t()}

  @doc """
  The release active in `tenant` that covers `target` (the invocation's target name), or
  `{:ok, nil}` when none does. Called with no transaction of its own open; an
  `{:error, reason}` refuses the request, since an approval cannot be bound to a release
  nobody could name.
  """
  @callback active(target :: String.t(), tenant :: term()) ::
              {:ok, active() | nil} | {:error, term()}
end
