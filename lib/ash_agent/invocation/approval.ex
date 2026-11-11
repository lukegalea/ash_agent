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
  `approval_expires_in`, and no action changes them. `provide_info` starts a new
  approval window when a row returns to its approver, from the same declaration as it
  was snapshotted.

  An approval holds while the same digest is computed again from the row with the target
  as it is declared now and each precondition's record as it stands now, and until
  `approval_expires_at`. `stale_reason/2` answers that; `apply_decision` asks it before
  an approval makes a row ready, and `claim` asks it again before every attempt, so an
  approval granted for one request never runs a different one.
  """

  alias AshAgent.Approval.Posture
  alias AshAgent.Digest
  alias AshAgent.Invocation.{Info, Target}

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

  @doc """
  The approval rule for `invocation`'s target under the posture in force in
  `opts[:tenant]`: `Posture.rule/3` with the facts gathered from the row's
  executing principal and the host's `Authority`.

  The posture is asked only of a `:four_eyes` target; `:none` and `:confirm`
  are the same under every posture, so the host is not asked. The role's
  holders are asked only under `:small_team`, the only rule that reads them. A
  host naming no authority (which the `invocation` section's verifier refuses)
  is answered as `:standard`.
  """
  @spec rule(Ash.Resource.record(), keyword()) :: Posture.rule()
  def rule(invocation, opts \\ []) do
    effect = invocation.effects || %{}

    if invocation.approval_mode == :four_eyes do
      now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
      authority = Info.authority(invocation.__struct__)
      {posture, ends_at} = posture(authority, opts)
      effective = Posture.effective(posture, ends_at, now)

      Posture.rule(
        effective,
        effect,
        facts(effective, authority, invocation, opts)
      )
    else
      Posture.rule(:standard, effect, %{})
    end
  end

  @doc """
  What an approval of `invocation` decided by `approver_id` rests on: `rule/2`
  under `opts[:tenant]`, refined by `Posture.basis/3`.
  """
  @spec basis(Ash.Resource.record(), String.t() | nil, keyword()) :: Posture.basis() | nil
  def basis(invocation, approver_id, opts \\ []) do
    invocation
    |> rule(opts)
    |> Posture.basis(approver_id, requester_person(invocation))
  end

  # The posture the host answers, and the facts its rule reads. Both are asked
  # with the row's tenant and no actor: facts about people, not authority.
  defp posture(nil, _opts), do: {:standard, nil}

  defp posture(authority, opts),
    do: authority.posture(opts[:tenant])

  # Only `:small_team` reads who holds the approver role; every other posture
  # reads whether the requester is a person alone.
  defp facts(:small_team, authority, invocation, opts) do
    requester = requester_person(invocation)
    holders = holders(authority, opts, invocation.effects)

    %{
      requester_is_person?: person?(invocation),
      requester_holds_role?: is_binary(requester) and requester in holders,
      role_has_holders?: holders != []
    }
  end

  defp facts(_posture, _authority, invocation, _opts),
    do: %{requester_is_person?: person?(invocation)}

  defp holders(nil, _opts, _effects), do: []

  defp holders(authority, opts, effects) do
    case effects do
      %{approver_role: role} when is_atom(role) ->
        authority.holders(opts[:tenant], role)

      %{"approver_role" => role} when is_binary(role) ->
        authority.holders(opts[:tenant], String.to_existing_atom(role))

      _no_role ->
        []
    end
  end

  # The person the request serves: the principal itself when a person, else the
  # person an automation acts for, else nobody.
  defp requester_person(%{executing_principal: principal}), do: requester_person(principal)

  defp requester_person(%{type: :person, id: id}) when is_binary(id), do: id
  defp requester_person(%{type: :automation, on_behalf_of: id}) when is_binary(id), do: id
  defp requester_person(_principal), do: nil

  defp person?(%{executing_principal: principal}), do: person?(principal)
  defp person?(%{type: :person}), do: true
  defp person?(_principal), do: false

  @doc """
  When an approval requested at `now` for `effect` expires, or nil when it does not.
  `effect` is the declaration, or its snapshot on a row (`AshAgent.Effects.Effect.to_map/1`).
  """
  @spec expires_at(AshAgent.Effects.Effect.t() | map(), DateTime.t()) :: DateTime.t() | nil
  def expires_at(%{approval_expires_in: duration}, now), do: expires_in(duration, now)
  def expires_at(%{"approval_expires_in" => duration}, now), do: expires_in(duration, now)
  def expires_at(_effect, _now), do: nil

  @seconds %{days: 86_400, hours: 3_600, minutes: 60}

  defp expires_in(duration, now) when is_list(duration) or is_map(duration) do
    seconds =
      Enum.reduce(duration, 0, fn {unit, n}, acc -> acc + n * Map.fetch!(@seconds, unit(unit)) end)

    DateTime.add(now, seconds, :second)
  end

  defp expires_in(nil, _now), do: nil

  defp unit(unit) when is_atom(unit), do: unit
  defp unit("days"), do: :days
  defp unit("hours"), do: :hours
  defp unit("minutes"), do: :minutes

  @doc """
  Why the approval `invocation` carries no longer holds, or nil while it does (and for a
  row that needs none).

    * `"approval_expired"`: `approval_expires_at` has passed;
    * `"target_changed"`: the target is declared differently now, or no longer resolves;
    * `"subject_changed"`: a precondition's record has a different `version_number` now,
      or is gone;
    * `"manifest_changed"`: the release active now is not the one the approval was bound to
      (`AshAgent.ReleaseManifest`; only for a resource that declares one);
    * `"approval_changed"`: anything else the digest covers differs from what was
      approved, such as an `authorization_details` that is not the one digested.

    * `"approved_by_requester"`: the approval was the requester's own, and the
      posture in force no longer allows that (raised to `:standard`, or an
      `:implementation` that ended). The posture is asked of a `:four_eyes`
      target only, with `opts[:approver]` as the person deciding: the
      `decided_by_id` of an arriving decision, and at a claim the row's
      `approved_by_id`.

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
      manifest_digest = current_manifest_digest(invocation, opts)

      cond do
        target_digest != invocation.target_digest ->
          "target_changed"

        preconditions != invocation.preconditions ->
          "subject_changed"

        manifest_digest != bound_manifest_digest(invocation) ->
          "manifest_changed"

        bound(invocation, target_digest, preconditions, manifest_digest) !=
            invocation.approval_digest ->
          "approval_changed"

        excluded_requester?(invocation, opts, now) ->
          "approved_by_requester"

        true ->
          nil
      end
    end
  end

  defp expired?(%{approval_expires_at: %DateTime{} = at}, now),
    do: DateTime.compare(at, now) != :gt

  defp expired?(_invocation, _now), do: false

  # A self-approval the posture in force no longer allows: the person deciding
  # is the person the request serves, and the rule in force now excludes them.
  # Only the rule's `exclude_requester?` edge is read, which no role fact
  # changes.
  defp excluded_requester?(%{approval_mode: :four_eyes} = invocation, opts, now) do
    approver = Keyword.get(opts, :approver, invocation.approved_by_id)
    rule = rule(invocation, Keyword.put(opts, :now, now))

    rule.exclude_requester? and is_binary(approver) and
      approver == requester_person(invocation)
  end

  defp excluded_requester?(_invocation, _opts, _now), do: false

  defp current_target_digest(invocation) do
    case Target.resolve(invocation.target) do
      {:ok, target} -> Target.digest(target)
      {:error, _unresolvable} -> nil
    end
  end

  # The digest of what the row says was approved, with what can change since put back as
  # it is now.
  # The digest of the release active now, or, for a resource that declares none, the one
  # the row recorded (which is nil), so nothing is compared.
  defp current_manifest_digest(invocation, opts) do
    case Info.release_manifest(invocation.__struct__) do
      nil ->
        bound_manifest_digest(invocation)

      module ->
        case module.active(invocation.target, opts[:tenant]) do
          {:ok, %{digest: digest}} -> digest
          _none_or_unreadable -> nil
        end
    end
  end

  defp bound_manifest_digest(%{authorization_details: [%{"manifest_digest" => digest} | _]}),
    do: digest

  defp bound_manifest_digest(_invocation), do: nil

  defp bound(
         %{authorization_details: details} = invocation,
         target_digest,
         preconditions,
         manifest_digest
       )
       when is_list(details) do
    details
    |> Enum.map(fn entry ->
      Map.merge(entry, %{
        "target_digest" => target_digest,
        "args_digest" => invocation.args_digest,
        "preconditions" => preconditions,
        "manifest_digest" => manifest_digest
      })
    end)
    |> digest()
  end

  defp bound(_invocation, _target_digest, _preconditions, _manifest_digest), do: nil
end
