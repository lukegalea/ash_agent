# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshAgent.RunTest do
  @moduledoc false
  use AshAgent.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  require Ash.Query

  alias AshAgent.AgentVersion.Definition
  alias AshAgent.Invocation.Executor
  alias AshAgent.Run.Stepper
  alias AshAgent.Test.{Agents.CheckReader, Domain, ExecutionIdentity, ScriptedModel}
  alias AshAgent.Test.{CredentialCheck, Invocation, Run}

  @agent "clinic.check_reader"
  @record "credential_check_record"
  @read "credential_check_read"

  setup do
    on_exit(fn ->
      ExecutionIdentity.restore()
      Application.delete_env(:ash_agent, :check_reader_output)
    end)

    ScriptedModel.script!([])
    nurse = %{id: "nurse-#{System.unique_integer([:positive])}"}
    ExecutionIdentity.grant_start(nurse.id, @agent)
    %{nurse: nurse}
  end

  defp machinery, do: [actor: %{id: "machinery"}]

  defp published!(extra \\ %{}) do
    CheckReader
    |> Domain.register_agent!()
    |> Domain.publish_agent_version!(extra)
  end

  defp start!(nurse, input \\ "SYNTHETIC: what is missing for clinician RN-1?") do
    published!()
    Domain.start_run!(@agent, input, actor: nurse)
  end

  defp step(run), do: Stepper.step(Run, run.id, machinery())
  defp reload(run), do: Domain.get_run!(run.id)

  defp steps(run),
    do: Domain.list_steps!(query: [filter: [run_id: run.id], sort: [seq: :asc]])

  defp invocations(run),
    do:
      Invocation
      |> Ash.Query.filter(run_id == ^run.id)
      |> Ash.Query.sort(invocation_key: :asc)
      |> Ash.read!()

  defp execute!(row), do: {:ok, :succeeded} = Executor.execute(Invocation, row.id, machinery())

  defp needs_step?(run), do: Ash.load!(reload(run), :needs_step).needs_step

  defp record_call(id, licence),
    do:
      {id, @record,
       %{"input" => %{"licence_number" => licence, "clinician_name" => "SYNTHETIC Dana Reyes"}}}

  defp expire_lease!(run) do
    past = DateTime.add(DateTime.utc_now(), -60, :second)

    {1, _} =
      Repo.update_all(
        from(r in "agent_runs", where: r.id == type(^run.id, Ecto.UUID)),
        set: [lease_expires_at: past]
      )

    :ok
  end

  defp text(message), do: Enum.map_join(message.content, & &1.text)

  defp tool_results(request),
    do: for(%{role: :tool} = message <- request.messages, do: message.tool_call_id)

  describe "start" do
    test "pins the agent's latest published version and queues the first step", %{nurse: nurse} do
      version = published!()
      run = Domain.start_run!(@agent, "SYNTHETIC: check RN-1", actor: nurse)

      assert %{status: :queued, agent_key: @agent, step_seq: 0} = run
      assert run.agent_version_id == version.id
      assert run.executing_principal == %{type: :person, id: nurse.id}
      assert run.budget_limit == 10_000
      assert DateTime.diff(run.deadline_at, DateTime.utc_now()) in 3_590..3_600
      assert run.run_key =~ ~r/^run:/
      assert needs_step?(run)
    end

    test "a requester without the agent's start grant is refused, and no run is written" do
      published!()
      stranger = %{id: "stranger-#{System.unique_integer([:positive])}"}

      assert {:error, %Ash.Error.Forbidden{errors: [%AshAgent.Invocation.NoPrincipal{} = error]}} =
               Domain.start_run(@agent, "SYNTHETIC: check RN-1", actor: stranger)

      assert error.reason == :no_start_grant
      assert Ash.read!(Run) == []
    end

    test "an agent with no published version cannot be started", %{nurse: nurse} do
      Domain.register_agent!(CheckReader)

      assert {:error, %Ash.Error.Invalid{} = error} =
               Domain.start_run(@agent, "SYNTHETIC: check RN-1", actor: nurse)

      assert Exception.message(error) =~ "no published version of #{@agent}"
    end

    test "an automation authority runs the run as that principal, acting for the requester",
         %{nurse: nurse} do
      published!(%{authority: %{"type" => "automation", "name" => "intake"}})
      run = Domain.start_run!(@agent, "SYNTHETIC: check RN-1", actor: nurse)

      assert run.executing_principal ==
               %{type: :automation, id: "intake", on_behalf_of: nurse.id, agent: @agent}
    end
  end

  describe "a step" do
    test "an answer is cast to the output type and completes the run", %{nurse: nurse} do
      ScriptedModel.script!([{:text, ~s({"missing": 0})}])
      run = start!(nurse)

      assert {:ok, :completed} = step(run)

      run = reload(run)
      assert run.status == :completed
      assert run.output == %{"value" => %{"missing" => 0}}
      assert %{step_count: 1, step_seq: 1, budget_spent: 48} = run
      assert run.prompt_fingerprint

      assert [%{seq: 1, role: :assistant, prompt_fingerprint: fingerprint}] = steps(run)
      assert fingerprint == run.prompt_fingerprint

      assert [request] = ScriptedModel.requests()
      assert request.caller == "run:#{run.id}:1"

      assert Enum.sort(request.tools) ==
               Enum.sort([@read, @record, "credential_check_record_reviewed"])
    end

    test "a governed call is an invocation the run waits for; its recorded result is what the model reads",
         %{nurse: nurse} do
      ScriptedModel.script!([
        {:tools, [record_call("call_a", "RN-1")]},
        {:text, ~s({"recorded": 1})}
      ])

      run = start!(nurse)

      assert {:ok, :waiting} = step(run)

      assert %{status: :waiting, blocked_on: :tools, step_count: 1, tool_call_count: 1} =
               reload(run)

      assert [row] = invocations(run)
      assert row.invocation_key == "run:#{run.id}:1:call_a"
      assert {row.run_id, row.step_seq, row.tool_call_id} == {run.id, 1, "call_a"}
      assert row.kind == :tool_call
      assert row.status == :ready
      assert row.executing_principal == %{type: :person, id: nurse.id}
      assert row.args == %{"licence_number" => "RN-1", "clinician_name" => "SYNTHETIC Dana Reyes"}

      # Nothing to do while the invocation is open: no claim, no model call.
      refute needs_step?(run)
      assert {:ok, :skipped} = step(run)
      assert length(ScriptedModel.requests()) == 1

      execute!(row)
      assert needs_step?(run)

      assert {:ok, :completed} = step(run)
      assert reload(run).output == %{"value" => %{"recorded" => 1}}

      assert [%{role: :assistant}, %{role: :tool}, %{role: :assistant}] = steps(run)

      [_first, second] = ScriptedModel.requests()
      assert tool_results(second) == ["call_a"]
      assert second.caller == "run:#{run.id}:3"

      [check] = Ash.read!(CredentialCheck, actor: nurse)
      assert second.messages |> Enum.find(&(&1.role == :tool)) |> text() =~ check.id
    end

    test "a worker that dies after two tools completed: the next step reuses both results",
         %{nurse: nurse} do
      ScriptedModel.script!([
        {:tools, [record_call("call_a", "RN-1"), record_call("call_b", "RN-2")]},
        {:die, :worker_killed},
        {:text, ~s({"recorded": 2})}
      ])

      run = start!(nurse)
      assert {:ok, :waiting} = step(run)
      Enum.each(invocations(run), &execute!/1)

      # The worker dies during its model call, after it recorded the two results.
      {pid, ref} = spawn_monitor(fn -> step(run) end)
      assert_receive {:DOWN, ^ref, :process, ^pid, :worker_killed}, 5_000

      assert %{status: :running, step_seq: 3} = reload(run)
      refute needs_step?(run)

      # Its lease expires; the run is queued again and steps.
      expire_lease!(run)
      assert %{status: :queued} = Domain.recover_run!(reload(run), machinery())
      assert {:ok, :completed} = step(run)

      # Both invocations ran once; neither was requested or run again.
      assert [%{attempt_count: 1, status: :succeeded}, %{attempt_count: 1, status: :succeeded}] =
               invocations(run)

      assert length(Ash.read!(CredentialCheck, actor: nurse)) == 2

      # The killed call and its repeat are the same request, under the same name.
      [_first, killed, repeated] = ScriptedModel.requests()
      assert killed.caller == repeated.caller
      assert killed.messages == repeated.messages
      assert tool_results(repeated) == ["call_a", "call_b"]

      assert [:assistant, :tool, :tool, :assistant] = Enum.map(steps(run), & &1.role)
    end

    test "a stale append is refused", %{nurse: nurse} do
      run = start!(nurse)

      {:ok, first} = Stepper.claim(Stepper.due(Run, run.id, machinery()) |> elem(1), machinery())
      expire_lease!(run)
      Domain.recover_run!(reload(run), machinery())
      {:ok, second} = Stepper.claim(reload(run), machinery())
      assert second.lease_epoch == first.lease_epoch + 1

      stale = %{epoch: first.lease_epoch, outcome: :running, steps: [user_text("late")]}

      assert {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Changes.StaleRecord{}]}} =
               Domain.record_step(first, stale, machinery())

      assert steps(run) == []

      assert {:ok, %{step_seq: 1}} =
               Domain.record_step(second, %{stale | epoch: second.lease_epoch}, machinery())
    end

    test "a duplicate job makes one model call", %{nurse: nurse} do
      ScriptedModel.script!([{:text, ~s({"missing": 0})}, {:text, ~s({"missing": 9})}])
      run = start!(nurse)

      # Two jobs that read the run before either claimed it: one claims.
      {:ok, read} = Stepper.due(Run, run.id, machinery())
      assert {:ok, %{status: :running}} = Stepper.claim(read, machinery())
      assert {:error, :not_claimable} = Stepper.claim(read, machinery())

      # A job after the step finished finds nothing to do.
      expire_lease!(run)
      Domain.recover_run!(reload(run), machinery())
      assert {:ok, :completed} = step(run)
      assert {:ok, :skipped} = step(run)

      assert length(ScriptedModel.requests()) == 1
      assert reload(run).output == %{"value" => %{"missing" => 0}}
    end

    test "an answer that does not cast is repaired up to max_repairs, then the run fails as rejected",
         %{nurse: nurse} do
      Application.put_env(:ash_agent, :check_reader_output, :integer)
      ScriptedModel.script!([{:text, "many"}, {:text, "still many"}, {:text, "7"}])
      run = start!(nurse)

      assert {:ok, :queued} = step(run)
      assert %{repair_count: 1} = reload(run)
      assert {:ok, :failed} = step(run)

      assert %{status: :failed, failure_class: :rejected, error_code: "output_uncastable"} =
               reload(run)

      assert [_first, second] = ScriptedModel.requests()
      assert %{role: :user} = repair = List.last(second.messages)
      assert text(repair) =~ "could not be read as integer"
      assert [:assistant, :user, :assistant] = Enum.map(steps(run), & &1.role)
    end

    test "an in-loop read runs as the executing actor, and the next step continues",
         %{nurse: nurse} do
      Ash.Seed.seed!(CredentialCheck, %{licence_number: "RN-VISIBLE"})

      Ash.Seed.seed!(CredentialCheck, %{
        licence_number: "RN-HIDDEN",
        restricted_to: "someone-else"
      })

      ScriptedModel.script!([{:tools, [{"call_r", @read, %{}}]}, {:text, ~s({"seen": 1})}])
      run = start!(nurse)

      assert {:ok, :queued} = step(run)
      assert [%{role: :assistant}, %{role: :tool, parts: [result]}] = steps(run)
      assert result["content"] =~ "RN-VISIBLE"
      refute result["content"] =~ "RN-HIDDEN"
      assert invocations(run) == []

      assert {:ok, :completed} = step(run)
    end

    test "a pinned version whose tools drifted fails the run closed, with no model call",
         %{nurse: nurse} do
      run = start!(nurse)
      version = Domain.get_agent_version!(run.agent_version_id)
      toolset = Enum.map(version.toolset, &Map.put(&1, "target_digest", "earlier"))

      {1, _} =
        Repo.update_all(
          from(v in "agent_versions", where: v.id == type(^version.id, Ecto.UUID)),
          set: [toolset: toolset]
        )

      assert {:ok, :failed} = step(run)

      assert %{status: :failed, failure_class: :permanent, error_code: "definition_drift"} =
               reload(run)

      assert ScriptedModel.requests() == []
    end

    test "a principal with no authority now fails the run as denied", %{nurse: nurse} do
      run = start!(nurse)
      ExecutionIdentity.revoke(nurse.id)

      assert {:ok, :failed} = step(run)

      assert %{failure_class: :denied, error_code: "no_authority: revoked"} = reload(run)
    end

    test "a run that has made max_steps model calls waits on its limit", %{nurse: nurse} do
      run = start!(nurse)

      {1, _} =
        Repo.update_all(
          from(r in "agent_runs", where: r.id == type(^run.id, Ecto.UUID)),
          set: [step_count: 6]
        )

      assert {:ok, :waiting} = step(run)
      assert %{status: :waiting, blocked_on: :limit, error_code: "max_steps"} = reload(run)
      refute needs_step?(run)
    end
  end

  describe "cancelling" do
    test "cancels the run's tool calls that have not started; what ran stays", %{nurse: nurse} do
      ScriptedModel.script!([
        {:tools, [record_call("call_a", "RN-1"), record_call("call_b", "RN-2")]}
      ])

      run = start!(nurse)
      assert {:ok, :waiting} = step(run)
      [ran, waiting] = invocations(run)
      execute!(ran)

      assert %{status: :cancelled} = Domain.request_run_cancel!(reload(run), actor: nurse)

      assert [%{status: :succeeded}, %{status: :cancelled}] = invocations(run)
      assert waiting.id == List.last(invocations(run)).id
      assert length(Ash.read!(CredentialCheck, actor: nurse)) == 1

      refute needs_step?(run)
      assert {:ok, :skipped} = step(run)
    end
  end

  defp user_text(text), do: %{role: :user, parts: [%{"type" => "text", "text" => text}]}

  test "publishing refuses an output type that names no Ash type" do
    draft = Domain.register_agent!(CheckReader)

    assert "output_type Nope.Type is not an Ash type" in Definition.publish_problems(%{
             draft
             | output_type: "Nope.Type"
           })
  end
end
