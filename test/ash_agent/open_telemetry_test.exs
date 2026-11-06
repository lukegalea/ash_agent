# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshAgent.OpenTelemetryTest do
  @moduledoc false
  use AshAgent.DataCase, async: false

  require Ash.Query

  alias AshAgent.Invocation.Executor
  alias AshAgent.OpenTelemetry, as: OTel
  alias AshAgent.Run.Stepper
  alias AshAgent.Test.{Agents.CheckReader, Domain, ExecutionIdentity, ScriptedModel}
  alias AshAgent.Test.{Invocation, Run}

  @agent "clinic.check_reader"
  @record "credential_check_record"
  @target "AshAgent.Test.CredentialCheck.record"
  @input "SYNTHETIC: what is missing for clinician RN-1?"

  @step [:ash_agent, :run, :step]
  @execute [:ash_agent, :invocation, :execute]

  # Every attribute the v1.41.0 conventions mark Opt-In for these spans: content.
  @opt_in [
    "gen_ai.input.messages",
    "gen_ai.output.messages",
    "gen_ai.system_instructions",
    "gen_ai.tool.definitions",
    "gen_ai.tool.call.arguments",
    "gen_ai.tool.call.result"
  ]

  setup do
    on_exit(&ExecutionIdentity.restore/0)

    ScriptedModel.script!([])
    nurse = %{id: "nurse-#{System.unique_integer([:positive])}"}
    ExecutionIdentity.grant_start(nurse.id, @agent)

    ref =
      :telemetry_test.attach_event_handlers(self(), [
        @step ++ [:start],
        @step ++ [:stop],
        @step ++ [:exception],
        @execute ++ [:start],
        @execute ++ [:stop],
        @execute ++ [:exception]
      ])

    on_exit(fn -> :telemetry.detach(ref) end)
    %{nurse: nurse}
  end

  defp machinery, do: [actor: %{id: "machinery"}]

  defp start!(nurse) do
    CheckReader
    |> Domain.register_agent!()
    |> Domain.publish_agent_version!(%{})

    Domain.start_run!(@agent, @input, actor: nurse)
  end

  defp step(run), do: Stepper.step(Run, run.id, machinery())

  defp record_call(id, licence),
    do:
      {id, @record,
       %{"input" => %{"licence_number" => licence, "clinician_name" => "SYNTHETIC Dana Reyes"}}}

  describe "the pinned version" do
    test "is semantic conventions v1.41.0" do
      assert OTel.version() == "1.41.0"
      assert OTel.schema_url() == "https://opentelemetry.io/schemas/1.41.0"
      assert OTel.events() == [@step, @execute]
    end
  end

  describe "a step" do
    test "is an invoke_agent span named for the agent, with the version's digest", %{nurse: nurse} do
      ScriptedModel.script!([{:text, ~s({"missing": 0})}])
      run = start!(nurse)

      assert {:ok, :completed} = step(run)

      assert_received {@step ++ [:start], ref, %{system_time: _},
                       %{run: claimed, agent_version: version}}

      assert_received {@step ++ [:stop], ^ref, %{duration: _},
                       %{result: {:ok, :completed}} = stop}

      assert claimed.id == run.id
      assert stop.run.id == run.id
      assert version.id == run.agent_version_id

      span = OTel.step(claimed, version, provider: "openai")

      assert span == %{
               name: "invoke_agent clinic.check_reader",
               kind: :internal,
               attributes: %{
                 "gen_ai.operation.name" => "invoke_agent",
                 "gen_ai.provider.name" => "openai",
                 "gen_ai.agent.name" => @agent,
                 "gen_ai.agent.version" => version.content_hash,
                 "gen_ai.conversation.id" => run.id
               }
             }

      assert OTel.status(:step, stop.result) == :ok
    end

    test "carries no content: not the input, the instructions or any opt-in attribute",
         %{nurse: nurse} do
      ScriptedModel.script!([{:text, ~s({"missing": 0})}])
      run = start!(nurse)
      assert {:ok, :completed} = step(run)
      assert_received {@step ++ [:start], _ref, _, %{run: claimed, agent_version: version}}

      %{attributes: attributes} = OTel.step(claimed, version, provider: "openai")

      assert Map.keys(attributes) -- @opt_in == Map.keys(attributes)

      for {_key, value} <- attributes do
        refute value =~ "SYNTHETIC"
        refute value == version.instructions
      end
    end

    test "with no version or provider known, leaves them out rather than inventing them",
         %{nurse: nurse} do
      run = start!(nurse)

      assert %{attributes: attributes, name: "invoke_agent clinic.check_reader"} =
               OTel.step(run, nil)

      refute Map.has_key?(attributes, "gen_ai.agent.version")
      refute Map.has_key?(attributes, "gen_ai.provider.name")
    end

    test "a job that claims nothing emits no span", %{nurse: nurse} do
      ScriptedModel.script!([{:text, ~s({"missing": 0})}])
      run = start!(nurse)
      assert {:ok, :completed} = step(run)
      assert_received {@step ++ [:start], _ref, _, _}
      assert_received {@step ++ [:stop], _ref, _, _}

      assert {:ok, :skipped} = step(run)
      refute_received {@step ++ [:start], _ref, _, _}
    end

    test "a worker that dies mid-step ends its span as an exception", %{nurse: nurse} do
      ScriptedModel.script!([{:die, :worker_killed}])
      run = start!(nurse)

      assert catch_exit(step(run)) == :worker_killed

      assert_received {@step ++ [:start], ref, _, _}
      assert_received {@step ++ [:exception], ^ref, %{duration: _}, %{kind: :exit}}
      refute_received {@step ++ [:stop], ^ref, _, _}
    end
  end

  describe "an invocation" do
    test "is an execute_tool span named for its target, with the run's tool call", %{nurse: nurse} do
      ScriptedModel.script!([{:tools, [record_call("call_a", "RN-1")]}])
      run = start!(nurse)
      assert {:ok, :waiting} = step(run)

      [row] = Invocation |> Ash.Query.filter(run_id == ^run.id) |> Ash.read!()
      assert {:ok, :succeeded} = Executor.execute(Invocation, row.id, machinery())

      assert_received {@execute ++ [:start], ref, _, %{invocation: claimed}}
      assert_received {@execute ++ [:stop], ^ref, _, %{result: {:ok, :succeeded}}}
      assert claimed.id == row.id

      assert OTel.tool(claimed) == %{
               name: "execute_tool " <> @target,
               kind: :internal,
               attributes: %{
                 "gen_ai.operation.name" => "execute_tool",
                 "gen_ai.tool.name" => @target,
                 "gen_ai.tool.type" => "function",
                 "gen_ai.tool.call.id" => "call_a",
                 "gen_ai.conversation.id" => run.id
               }
             }

      %{attributes: attributes} = OTel.tool(claimed)
      assert Map.keys(attributes) -- @opt_in == Map.keys(attributes)
      for {_key, value} <- attributes, do: refute(value =~ "RN-1")

      # Executing a finished row again claims nothing and emits nothing.
      assert {:ok, _} = Executor.execute(Invocation, row.id, machinery())
      refute_received {@execute ++ [:start], _ref, _, _}
    end

    test "outside a run, leaves the tool call and conversation out" do
      span = OTel.tool(%{target: @target, tool_call_id: nil, run_id: nil})

      assert span.attributes == %{
               "gen_ai.operation.name" => "execute_tool",
               "gen_ai.tool.name" => @target,
               "gen_ai.tool.type" => "function"
             }
    end
  end

  describe "status" do
    test "only the outcomes that finished the work read as ok" do
      for outcome <- [:completed, :waiting, :queued],
          do: assert(OTel.status(:step, {:ok, outcome}) == :ok)

      for outcome <- [:succeeded, :dispatched],
          do: assert(OTel.status(:tool, {:ok, outcome}) == :ok)

      for outcome <- Stepper.outcomes() -- OTel.ok_outcomes(:step) do
        assert OTel.status(:step, {:ok, outcome}) ==
                 {:error, %{"error.type" => Atom.to_string(outcome)}}
      end

      for outcome <- Executor.outcomes() -- OTel.ok_outcomes(:tool) do
        assert OTel.status(:tool, {:ok, outcome}) ==
                 {:error, %{"error.type" => Atom.to_string(outcome)}}
      end
    end

    test "an outcome of the other kind is not read as ok" do
      assert {:error, _} = OTel.status(:step, {:ok, :succeeded})
      assert {:error, _} = OTel.status(:tool, {:ok, :completed})
    end

    test "an error, an exception, nothing, or an answer it does not know is an error" do
      assert OTel.status(:tool, {:error, %ArgumentError{message: "x"}}) ==
               {:error, %{"error.type" => "ArgumentError"}}

      assert OTel.status(:step, %RuntimeError{message: "x"}) ==
               {:error, %{"error.type" => "RuntimeError"}}

      for unknown <- [
            {:error, :timeout},
            {:ok, :something_new},
            {:ok, nil},
            {:ok, "completed"},
            :ok,
            nil,
            %{},
            {:completed}
          ] do
        assert {:error, %{"error.type" => type}} = OTel.status(:step, unknown)
        refute type == "completed"
        assert {:error, _} = OTel.status(:tool, unknown)
      end
    end
  end
end
