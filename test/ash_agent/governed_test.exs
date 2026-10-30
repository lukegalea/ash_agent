# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshAgent.Validations.GovernedTest do
  @moduledoc false
  use AshAgent.DataCase, async: false

  alias AshAgent.Invocation.{Executor, Ungoverned}
  alias AshAgent.Test.{CredentialCheck, Domain}
  alias AshAgent.Validations.Governed

  @restrict "AshAgent.Test.CredentialCheck.restrict"
  @page "AshAgent.Test.CredentialCheck.page_board"
  @verify "AshAgent.Test.CredentialCheck.mark_verified"

  setup do
    check =
      CredentialCheck
      |> Ash.Changeset.for_create(:record, %{licence_number: "RN-#{System.unique_integer()}"})
      |> Ash.create!()

    %{nurse: %{id: Ash.UUID.generate()}, lead: %{id: Ash.UUID.generate()}, check: check}
  end

  defp machinery, do: [actor: %{id: "machinery"}]
  defp key, do: "test:#{System.unique_integer([:positive])}"
  defp invoke!(actor, target, args), do: Domain.invoke!(target, args, %{key: key()}, actor: actor)

  # Claims the row as the executor does, without running its target.
  defp claimed!(row) do
    {:ok, claimed} = Executor.claim(row, machinery())
    claimed
  end

  # Runs `restrict` on `check` directly, as `actor`, with `context` as its ash_agent context.
  defp restrict(check, restricted_to, actor, context) do
    check
    |> Ash.Changeset.for_update(:restrict, %{"restricted_to" => restricted_to},
      actor: actor,
      context: context
    )
    |> Ash.update()
  end

  defp context(claimed, changes \\ %{}),
    do: %{ash_agent: Map.merge(Executor.context(claimed), changes)}

  defp refusal({:error, %Ash.Error.Invalid{errors: errors}}) do
    assert [%Ungoverned{reason: reason}] = Enum.filter(errors, &match?(%Ungoverned{}, &1))
    reason
  end

  defp restricted_to(check),
    do: Ash.get!(CredentialCheck, check.id, authorize?: false).restricted_to

  describe "through its invocation" do
    test "a governed update runs, and stays atomic", %{nurse: nurse, check: check} do
      row = invoke!(nurse, @restrict, %{"id" => check.id, "restricted_to" => nurse.id})

      assert :succeeded = Domain.execute_invocation!(%{"id" => row.id}, machinery())
      assert restricted_to(check) == nurse.id

      # `restrict` keeps `require_atomic?`: the validation's `atomic/3` is what lets it.
      assert Ash.Resource.Info.action(CredentialCheck, :restrict).require_atomic?
      assert Governed.atomic?()
    end

    test "a governed generic action runs", %{nurse: nurse} do
      row = invoke!(nurse, @page, %{"licence_number" => "RN-1"})

      assert :succeeded = Domain.execute_invocation!(%{"id" => row.id}, machinery())
      assert Domain.get_invocation!(row.id).result == %{"value" => true}
    end

    test "it is temporal safe" do
      assert Governed.temporal_safe?(invocation: AshAgent.Test.Invocation)
    end
  end

  describe "outside its invocation" do
    test "called directly, it is refused and changes nothing", %{nurse: nurse, check: check} do
      assert :no_invocation = refusal(restrict(check, nurse.id, nurse, %{}))

      assert :no_invocation =
               CredentialCheck
               |> Ash.ActionInput.for_action(:page_board, %{licence_number: "RN-1"}, actor: nurse)
               |> Ash.run_action()
               |> refusal()

      assert restricted_to(check) == nil
    end

    test "a forged context is refused: no such row, a row not claimed, another epoch", %{
      nurse: nurse,
      check: check
    } do
      args = %{"id" => check.id, "restricted_to" => nurse.id}
      ready = invoke!(nurse, @restrict, args)

      forged = %{invocation_id: ready.id, invocation_key: ready.invocation_key, lease_epoch: 0}

      unknown = %{forged | invocation_id: Ash.UUID.generate()}

      assert :unknown_invocation =
               refusal(restrict(check, nurse.id, nurse, %{ash_agent: unknown}))

      # Requested, and so with the right target, arguments and principal, but not claimed.
      assert :not_executing = refusal(restrict(check, nurse.id, nurse, %{ash_agent: forged}))

      claimed = claimed!(ready)

      assert :not_executing =
               refusal(
                 restrict(
                   check,
                   nurse.id,
                   nurse,
                   context(claimed, %{lease_epoch: claimed.lease_epoch + 1})
                 )
               )

      assert restricted_to(check) == nil
    end

    test "other arguments are refused: other inputs, or another record", %{
      nurse: nurse,
      lead: lead,
      check: check
    } do
      claimed =
        claimed!(invoke!(nurse, @restrict, %{"id" => check.id, "restricted_to" => nurse.id}))

      assert :other_arguments = refusal(restrict(check, lead.id, nurse, context(claimed)))

      other =
        CredentialCheck
        |> Ash.Changeset.for_create(:record, %{licence_number: "RN-#{System.unique_integer()}"})
        |> Ash.create!()

      assert :other_arguments = refusal(restrict(other, nurse.id, nurse, context(claimed)))

      assert {restricted_to(check), restricted_to(other)} == {nil, nil}
    end

    test "an invocation of another action is refused", %{nurse: nurse, check: check} do
      claimed = claimed!(invoke!(nurse, @verify, %{"id" => check.id}))

      assert :other_target = refusal(restrict(check, nurse.id, nurse, context(claimed)))
    end

    test "another actor is refused, even with the invocation's context and arguments", %{
      nurse: nurse,
      lead: lead,
      check: check
    } do
      claimed =
        claimed!(invoke!(nurse, @restrict, %{"id" => check.id, "restricted_to" => nurse.id}))

      assert :other_principal = refusal(restrict(check, nurse.id, lead, context(claimed)))
      assert :other_principal = refusal(restrict(check, nurse.id, nil, context(claimed)))

      # The principal it executes as, with the same claim, may.
      assert {:ok, _} = restrict(check, nurse.id, nurse, context(claimed))
    end
  end

  test "it requires the invocation resource" do
    assert {:error, message} = Governed.init([])
    assert message =~ "invocation:"
  end
end
