# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshAgent.InvocationHostTest do
  @moduledoc false
  use ExUnit.Case, async: true

  import Spark.Test

  alias Spark.Error.DslError

  test "the test host supplies what the fragment needs" do
    assert AshAgent.Invocation.Info.execution_identity(AshAgent.Test.Invocation) ==
             AshAgent.Test.ExecutionIdentity

    assert AshAgent.Invocation.Info.digest_key(AshAgent.Test.Invocation) ==
             AshAgent.Test.DigestKey

    refute AshAgent.Invocation.Info.execute_trigger?(AshAgent.Test.Invocation)
  end

  test "a resource that includes the fragment must name its identity and digest key" do
    error =
      assert_dsl_error %DslError{path: [:invocation, :execution_identity]} do
        defmodule Elixir.AshAgent.InvocationHostTest.NoHostOptions do
          use Ash.Resource, domain: nil, fragments: [AshAgent.Invocation]
        end
      end

    assert error.message =~ "AshAgent.ExecutionIdentity"
  end

  test "a resource using AshOban must declare the :execute trigger" do
    error =
      assert_dsl_error %DslError{path: [:oban, :triggers]} do
        defmodule Elixir.AshAgent.InvocationHostTest.NoExecuteTrigger do
          use Ash.Resource,
            domain: nil,
            extensions: [AshOban],
            fragments: [AshAgent.Invocation]

          invocation do
            execution_identity AshAgent.Test.ExecutionIdentity
            digest_key AshAgent.Test.DigestKey
          end

          oban do
            domain AshAgent.Test.Domain
          end
        end
      end

    assert error.message =~ "trigger named :execute"
  end
end
