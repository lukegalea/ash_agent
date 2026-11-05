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
  and `manifest_digest` stays nil. The same module says which version of an agent live runs
  start on (`c:agent_version/2`).
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

  @doc """
  The id of the version of the agent `key` that the release active in `tenant` pins, or
  `{:ok, nil}` when no active release pins one.

  A live run (`AshAgent.Run`'s `start`) starts on that version instead of the agent's latest
  published one, so publishing a candidate does not make it live: a release does, by being
  promoted, and rolling back returns to the version the earlier release pinned. With no
  active release pinning the agent, the latest published version runs, as it does for a
  host that has no releases. Optional: a host that does not implement it starts every live
  run on the latest published version.
  """
  @callback agent_version(key :: String.t(), tenant :: term()) ::
              {:ok, Ash.UUID.t() | nil} | {:error, term()}

  @optional_callbacks agent_version: 2
end
