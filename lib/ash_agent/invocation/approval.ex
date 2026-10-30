# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshAgent.Invocation.Approval do
  @moduledoc """
  What an approval binds, and whether it still holds.

  A row that `request` routes to `awaiting_approval` records what an approver is shown
  and what their approval grants, in the shape of RFC 9396 `authorization_details`: one
  entry whose `type` names the action as a URN, with `actions`, an `identifier` (the
  subject's primary key, for an update or destroy) and four fields of its own:

      %{
        "type" => "urn:ash-agent:action:MyClinic.Credential.activate",
        "actions" => ["activate"],
        "identifier" => "8b0c…",
        "target_digest" => "…",
        "args_digest" => "…",
        "preconditions" => [%{"resource" => "MyClinic.Credential", "id" => "8b0c…", "version_number" => 4}],
        "manifest_digest" => nil
      }

  `approval_digest` is the SHA-256 of its RFC 8785 canonical JSON (`AshAgent.Digest`).
  Both are written by `request`, with `approval_expires_at` from the declaration's
  `approval_expires_in`, and no action changes them.

  An approval holds while the same digest is computed again from the row with the target
  as it is declared now and each precondition's record as it stands now, and until
  `approval_expires_at`. `stale_reason/2` answers that; `apply_decision` asks it before
  an approval makes a row ready, and `claim` asks it again before every attempt, so an
  approval granted for one request never runs a different one.
  """

  alias AshAgent.Digest
  alias AshAgent.Invocation.Target

  @type_prefix "urn:ash-agent:action:"

  @typedoc "Why an approval no longer holds."
  @type stale_reason :: String.t()

  @doc """
  The `authorization_details` of a request: `target` (its name), `target_digest`,
  `args_digest`, `preconditions` and, when the target acts on a record, `identifier`.
  """
  @spec details(map()) :: [map()]
  def details(fields) do
    entry = %{
      "type" => @type_prefix <> fields.target,
      "actions" => [fields.target |> String.split(".") |> List.last()],
      "target_digest" => fields.target_digest,
      "args_digest" => fields.args_digest,
      "preconditions" => fields.preconditions,
      "manifest_digest" => Map.get(fields, :manifest_digest)
    }

    case Map.get(fields, :identifier) do
      nil -> [entry]
      identifier -> [Map.put(entry, "identifier", identifier)]
    end
  end

  @doc "SHA-256 of the canonical JSON of `details`, as lowercase hex: the `approval_digest`."
  @spec digest([map()]) :: String.t()
  def digest(details), do: Digest.sha256_hex(details)

  @doc "When an approval requested at `now` for `effect` expires, or nil when it does not."
  @spec expires_at(AshAgent.Effects.Effect.t(), DateTime.t()) :: DateTime.t() | nil
  def expires_at(%{approval_expires_in: nil}, _now), do: nil

  def expires_at(%{approval_expires_in: duration}, now) do
    seconds =
      Enum.reduce(duration, 0, fn
        {:days, n}, acc -> acc + n * 86_400
        {:hours, n}, acc -> acc + n * 3_600
        {:minutes, n}, acc -> acc + n * 60
      end)

    DateTime.add(now, seconds, :second)
  end

  @doc """
  Why the approval `invocation` carries no longer holds, or nil while it does (and for a
  row that needs none).

    * `"approval_expired"`: `approval_expires_at` has passed;
    * `"target_changed"`: the target is declared differently now, or no longer resolves;
    * `"subject_changed"`: a precondition's record has a different `version_number` now,
      or is gone;
    * `"approval_changed"`: anything else the digest covers differs from what was
      approved, such as an `authorization_details` that is not the one digested.

  The preconditions' records are read without authorization, in `opts[:tenant]`: this is
  the machinery checking what was approved, not a person reading.
  """
  @spec stale_reason(Ash.Resource.record(), keyword()) :: stale_reason() | nil
  def stale_reason(invocation, opts \\ [])

  def stale_reason(%{approval_mode: :none}, _opts), do: nil

  def stale_reason(invocation, opts) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)

    if expired?(invocation, now) do
      "approval_expired"
    else
      target_digest = current_target_digest(invocation)
      preconditions = Target.current_preconditions(invocation.preconditions, opts)

      cond do
        target_digest != invocation.target_digest ->
          "target_changed"

        preconditions != invocation.preconditions ->
          "subject_changed"

        bound(invocation, target_digest, preconditions) != invocation.approval_digest ->
          "approval_changed"

        true ->
          nil
      end
    end
  end

  defp expired?(%{approval_expires_at: %DateTime{} = at}, now),
    do: DateTime.compare(at, now) != :gt

  defp expired?(_invocation, _now), do: false

  defp current_target_digest(invocation) do
    case Target.resolve(invocation.target) do
      {:ok, target} -> Target.digest(target)
      {:error, _unresolvable} -> nil
    end
  end

  # The digest of what the row says was approved, with what can change since put back as
  # it is now.
  defp bound(%{authorization_details: details} = invocation, target_digest, preconditions)
       when is_list(details) do
    details
    |> Enum.map(fn entry ->
      Map.merge(entry, %{
        "target_digest" => target_digest,
        "args_digest" => invocation.args_digest,
        "preconditions" => preconditions
      })
    end)
    |> digest()
  end

  defp bound(_invocation, _target_digest, _preconditions), do: nil
end
