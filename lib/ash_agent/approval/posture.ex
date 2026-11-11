# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshAgent.Approval.Posture do
  @moduledoc """
  How a tenant decides approvals when its people are few, or it is being set up:
  a closed set of three postures, one rule table, no I/O.

  A posture changes *which person* decides an approval, never *whether* a person
  decides: an agent, an engine or an automation principal is never a candidate
  (`AshAgent.ExecutionIdentity`). It never widens what anyone may do: the host's
  grants still apply when the target runs, and the approval binding
  (`AshAgent.Invocation.Approval`) is the same under every posture.

  | Posture | A `:four_eyes` target | Ends |
  |---|---|---|
  | `:standard` (the default) | Another holder of the approver role approves; the requester is excluded | Never |
  | `:small_team` | The requester may approve their own request if they hold the approver role. If nobody holds that role, any holder of the administrator role may approve, the requester included | Never; a person turns it off |
  | `:implementation` | The requester confirms it themselves; no approver role is needed | A required end date, at most `max_implementation_days/0` after it is set |

  `:none` and `:confirm` targets behave as declared under every posture. An end
  date that has passed makes the posture `:standard` (`effective/3`).

  The tenant's posture and its end date live on a resource that includes
  `AshAgent.Approval.PostureFragment`; the host answers for them, its role
  holders and its operators, through `AshAgent.Approval.Authority`. This module
  is the rule alone: give it to `rule/3` (through
  `AshAgent.Invocation.Approval.rule/2`, which gathers the facts) and read the
  candidates it names.
  """

  @postures [:standard, :small_team, :implementation]
  @max_implementation_days 120
  @bases [:confirm, :four_eyes, :small_team, :implementation]

  @typedoc "One of the three postures."
  @type posture :: :standard | :small_team | :implementation

  @typedoc """
  What an approval rested on: the declaration (`:confirm`, `:four_eyes`) or the
  posture (`:small_team`, `:implementation`).
  """
  @type basis :: :confirm | :four_eyes | :small_team | :implementation

  @typedoc "What the host answers about the requester and the approver role."
  @type facts :: %{
          optional(:requester_holds_role?) => boolean,
          optional(:role_has_holders?) => boolean,
          optional(:requester_is_person?) => boolean
        }

  @typedoc """
  Who may decide one approval:

    * `candidates`: the pool the rule names — `:approver_role` (holders of the
      declared role), `:administrators` (holders of the administrator role),
      `:requester` (the requester themself, a person), or `nil` when the rule
      names nobody (`:none` asks no approval; `:confirm` asks a person the
      declaration leaves the host to choose);
    * `exclude_requester?`: the requester is not among the candidates, so a
      decision by them rests on nothing. `AshAgent.Invocation.Approval` enforces
      this edge, the one the package can see without reading the host's grants;
      membership in the pool is the host's to check, as it is today;
    * `basis`: what an approval from the pool rests on, refined per decision by
      `basis/3`.
  """
  @type rule :: %{
          candidates: :approver_role | :administrators | :requester | nil,
          exclude_requester?: boolean(),
          basis: basis() | nil
        }

  @doc "The closed set of postures, strictest first."
  @spec postures() :: [posture()]
  def postures, do: @postures

  @doc "How long an `:implementation` posture may run from the day it is set."
  @spec max_implementation_days() :: pos_integer()
  def max_implementation_days, do: @max_implementation_days

  @doc "The four values an approval's `approval_basis` may take."
  @spec bases() :: [basis()]
  def bases, do: @bases

  @doc """
  The posture in force at `now`: `posture` with its `ends_at`, which nothing
  supplies for `:standard` and `:small_team`.

  An end date that has passed makes the posture `:standard`. So does an
  `:implementation` with no end date: it cannot run without one. Any posture a
  host answers that is not one of `postures/0` is `:standard`, the strictest
  answer there is.
  """
  @spec effective(posture() | term(), DateTime.t() | nil, DateTime.t()) :: posture()
  def effective(posture, ends_at, now) do
    cond do
      passed?(ends_at, now) ->
        :standard

      posture == :implementation and not is_struct(ends_at, DateTime) ->
        :standard

      true ->
        in_force(posture)
    end
  end

  # An end date that has passed ends any posture.
  defp passed?(%DateTime{} = ends_at, %DateTime{} = now),
    do: DateTime.compare(ends_at, now) != :gt

  defp passed?(_ends_at, _now), do: false

  defp in_force(:small_team), do: :small_team
  defp in_force(:implementation), do: :implementation
  defp in_force(_posture), do: :standard

  @doc """
  Who may decide one approval of the target whose effects snapshot `effect` is,
  under the posture `posture` already made effective (`effective/3`).

  `effect` is the declaration as `AshAgent.Effects.Effect.to_map/1` snapshots it
  (or the struct itself); `facts` is what the host answers about the requester
  and the role. The table:

  | Target | Posture in force | Facts | Candidates | Exclude requester | Basis |
  |---|---|---|---|---|---|
  | `:none` | any | any | nobody (`nil`) | — | — |
  | `:confirm` | any | any | nobody (`nil`); the host chooses a person | no | `:confirm` |
  | `:four_eyes` | any, `posture_floor?` | any | the approver role | yes | `:four_eyes` |
  | `:four_eyes` | `:standard` | any | the approver role | yes | `:four_eyes` |
  | `:four_eyes` | `:small_team` | the role has holders | the approver role | only when the requester does not hold it | `:four_eyes` |
  | `:four_eyes` | `:small_team` | the role has no holders | the administrators | no | `:small_team` |
  | `:four_eyes` | `:implementation` | the requester is a person | the requester | no | `:implementation` |
  | `:four_eyes` | `:implementation` | the requester is not a person | the approver role | yes | `:four_eyes` |

  An effect declared `posture_floor?: true` keeps `:standard` behaviour under
  every posture. An `:implementation` whose requester is not a person falls back
  to `:standard` behaviour too: the posture would have the requester confirm
  their own request, and a posture never changes whether a person decides.
  """
  @spec rule(posture(), AshAgent.Effects.Effect.t() | map(), facts()) :: rule()
  def rule(posture, effect, facts \\ %{})

  def rule(_posture, %{approval: :none}, _facts),
    do: %{candidates: nil, exclude_requester?: false, basis: nil}

  def rule(_posture, %{"approval" => "none"}, _facts),
    do: %{candidates: nil, exclude_requester?: false, basis: nil}

  # `:confirm` asks a person the declaration leaves the host to choose; no
  # posture changes it, and the declaration excludes nobody.
  def rule(_posture, %{approval: :confirm}, _facts),
    do: %{candidates: nil, exclude_requester?: false, basis: :confirm}

  def rule(_posture, %{"approval" => "confirm"}, _facts),
    do: %{candidates: nil, exclude_requester?: false, basis: :confirm}

  def rule(posture, effect, facts) when posture in @postures do
    if floored?(effect) do
      standard()
    else
      four_eyes(posture, facts)
    end
  end

  # A target the package does not know, under a posture it does not know: the
  # strictest row there is.
  def rule(_posture, _effect, _facts), do: standard()

  defp standard, do: %{candidates: :approver_role, exclude_requester?: true, basis: :four_eyes}

  defp four_eyes(:standard, _facts), do: standard()

  defp four_eyes(:small_team, facts) do
    if facts[:role_has_holders?] do
      %{
        candidates: :approver_role,
        exclude_requester?: not facts[:requester_is_person?] or not facts[:requester_holds_role?],
        basis: :four_eyes
      }
    else
      %{candidates: :administrators, exclude_requester?: false, basis: :small_team}
    end
  end

  defp four_eyes(:implementation, facts) do
    if facts[:requester_is_person?] do
      %{candidates: :requester, exclude_requester?: false, basis: :implementation}
    else
      standard()
    end
  end

  defp floored?(%AshAgent.Effects.Effect{posture_floor?: true}), do: true
  defp floored?(%{posture_floor?: true}), do: true
  defp floored?(%{"posture_floor" => true}), do: true
  defp floored?(_effect), do: false

  @doc """
  What an approval decided by `approver_id` rests on under `rule`, where
  `requester_id` is the person the request serves (`nil` when it serves none).

  `rule/3` names the pool; this names the decision:

    * the requester approving their own request under a `:four_eyes` pool rests
      on `:small_team`, the only posture that leaves them a candidate;
    * anyone else approving while the rule named the requester alone
      (`:implementation`) rests on the declaration's four eyes, which they
      satisfied a fortiori;
    * every other decision rests on the rule's own basis.
  """
  @spec basis(rule(), String.t() | nil, String.t() | nil) :: basis() | nil
  def basis(%{basis: :four_eyes} = _rule, approver_id, requester_id)
      when is_binary(approver_id) and approver_id == requester_id,
      do: :small_team

  # The requester confirming their own request under the posture that named
  # them alone rests on that posture, not on the pool.
  def basis(%{candidates: :requester, basis: basis}, approver_id, requester_id)
      when is_binary(approver_id) and approver_id == requester_id,
      do: basis

  # Anyone else approving while the rule named the requester alone rests on the
  # declaration's four eyes.
  def basis(%{candidates: :requester, basis: :implementation}, _approver, _requester),
    do: :four_eyes

  def basis(%{basis: basis}, _approver_id, _requester_id), do: basis
end
