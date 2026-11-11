# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshAgent.Approval.Validations.PostureChange do
  @moduledoc """
  Who may set a tenant's approval posture (`set_approval_posture` on
  `AshAgent.Approval.PostureFragment`), and what an `:implementation` posture
  needs. Policies stay with the host: this is the rule about the change itself,
  asked of the actor the host's policies already let through.

    * **The end date.** `:implementation` requires an end date in the future and
      at most `AshAgent.Approval.Posture.max_implementation_days/0` days out.
      Every other posture clears it (the action's change does); a date supplied
      for one is not an error, it is discarded.

    * **Raising** the posture (towards `:standard`, or an `:implementation`
      window made shorter) is the work of one administrator.

    * **Lowering** it (away from `:standard`, or an `:implementation` window
      made longer) needs one of:

        * the actor is the only person who has ever held the administrator role
          (`c:AshAgent.Approval.Authority.holders/2` returns exactly them);
        * the actor is an operator (`c:AshAgent.Approval.Authority.operator?/1`);
        * the change arrives through an approved four-eyes invocation. That is
          the seam: the host names its invocation resource in the
          `approval_posture` section and declares this action a four-eyes target
          with `posture_floor?: true`, so its approval is four eyes under every
          posture. The invocation the context names is then verified exactly as
          `AshAgent.Validations.Governed` verifies one (`verify/3`): executing
          under the lease its executor holds, for this action, these inputs and
          this actor. A context is only what the caller says, so a marker that
          does not verify counts for nothing.

  A refusal is `AshAgent.Approval.PostureChangeRefused`. A request to lower the
  posture through an invocation is not refused for it at request time, when the
  approval it asks for does not exist yet (`AshAgent.Invocation.Target.precheck/3`);
  the claim runs this validation again, with the approval in hand.

  The person deciding is the actor mapped through the host's
  `AshAgent.ExecutionIdentity` (`principal_of/1`): an automation principal or an
  actor the host does not recognize decides nothing here, alone.
  """

  use Ash.Resource.Validation

  alias AshAgent.Approval.{Info, Posture, PostureChangeRefused}
  alias AshAgent.Validations.Governed

  @postures Posture.postures()
  @rank %{standard: 2, small_team: 1, implementation: 0}

  @impl true
  def validate(changeset, _opts, context) do
    new = Ash.Changeset.get_attribute(changeset, :approval_posture)
    ends_at = Ash.Changeset.get_attribute(changeset, :approval_posture_ends_at)

    with :ok <- end_date(new, ends_at) do
      who_may(
        changeset,
        context,
        {changeset.data.approval_posture, changeset.data.approval_posture_ends_at},
        {new, ends_at}
      )
    end
  end

  defp end_date(posture, _ends_at) when posture not in @postures,
    do: {:error, field: :approval_posture, message: "is not one of the postures"}

  defp end_date(:implementation, nil),
    do:
      {:error,
       field: :approval_posture_ends_at, message: "an :implementation posture needs an end date"}

  defp end_date(:implementation, ends_at) do
    now = DateTime.utc_now()
    latest = DateTime.add(now, Posture.max_implementation_days(), :day)

    cond do
      DateTime.compare(ends_at, now) != :gt ->
        {:error, field: :approval_posture_ends_at, message: "the end date is in the past"}

      DateTime.compare(ends_at, latest) == :gt ->
        {:error,
         field: :approval_posture_ends_at,
         message: "the end date is more than %{days} days out",
         vars: [days: Posture.max_implementation_days()]}

      true ->
        :ok
    end
  end

  defp end_date(_posture, _ends_at), do: :ok

  # Nothing changes: only the end-date rule was asked.
  defp who_may(_changeset, _context, {posture, ends_at}, {posture, ends_at}), do: :ok

  defp who_may(changeset, context, {old_posture, old_ends_at}, {new_posture, ends_at}) do
    loosened? =
      @rank[new_posture] < @rank[old_posture] or
        (old_posture == :implementation and later?(ends_at, old_ends_at))

    if loosened? do
      if operator?(changeset, context) or sole_administrator?(changeset, context) or
           through_invocation?(changeset, context) do
        :ok
      else
        {:error, PostureChangeRefused.exception(reason: :lowering)}
      end
    else
      if operator?(changeset, context) or administrator?(changeset, context) or
           through_invocation?(changeset, context) do
        :ok
      else
        {:error, PostureChangeRefused.exception(reason: :raising)}
      end
    end
  end

  # An :implementation window made longer is the posture loosened; a missing
  # window that grows one is treated the same, strictly.
  defp later?(ends_at, old_ends_at) when is_map(ends_at) and is_map(old_ends_at),
    do: DateTime.compare(ends_at, old_ends_at) == :gt

  defp later?(ends_at, nil) when is_map(ends_at), do: true
  defp later?(_ends_at, _old_ends_at), do: false

  defp operator?(changeset, context) do
    case Info.authority(changeset.resource) do
      nil -> false
      authority -> authority.operator?(context.actor)
    end
  end

  defp administrator?(changeset, context) do
    person_id = person_id(changeset, context)
    person_id != nil and person_id in administrators(changeset, context)
  end

  defp sole_administrator?(changeset, context) do
    person_id = person_id(changeset, context)

    person_id != nil and administrators(changeset, context) == [person_id]
  end

  defp administrators(changeset, context) do
    case Info.authority(changeset.resource) do
      nil ->
        []

      authority ->
        authority.holders(context.tenant, authority.administrator_role())
    end
  end

  # The person deciding: the actor mapped through the host's execution identity.
  defp person_id(changeset, context) do
    case Info.execution_identity(changeset.resource) do
      nil ->
        nil

      identity ->
        case identity.principal_of(context.actor) do
          {:ok, %{type: :person, id: id}} when is_binary(id) -> id
          _not_a_person -> nil
        end
    end
  end

  # The seam: an invocation the host's executor is running, verified as
  # `Governed` verifies one, of an action the host declared four eyes at the
  # floor, so the approval behind it was four eyes under every posture.
  defp through_invocation?(changeset, context) do
    invocation = Info.invocation(changeset.resource)

    not is_nil(invocation) and floored_four_eyes?(changeset) and
      Governed.verify(changeset, invocation, context.actor) == :ok
  end

  defp floored_four_eyes?(%{resource: resource, action: action}) do
    match?(
      %{approval: :four_eyes, posture_floor?: true},
      AshAgent.Effects.Info.effect(resource, action.name)
    )
  end
end
