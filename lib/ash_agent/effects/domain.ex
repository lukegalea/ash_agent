# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshAgent.Effects.Domain do
  @moduledoc """
  A Spark extension for domains: every action the domain exposes as an ash_ai
  tool must have an `AshAgent.Effects` declaration.

  It adds no DSL; it adds a verifier over the domain's `tools` and the `tools` of
  its resources. An undeclared tool action is

    * a compile error when its resource uses `AshAgent.Effects`. A resource that
      declares effects carries governed targets, and every action it exposes must
      say what it does;
    * a compile warning otherwise, so a host can adopt the declaration resource by
      resource.

  ```elixir
  defmodule MyClinic.Credentialing do
    use Ash.Domain, extensions: [AshAi, AshAgent.Effects.Domain]

    tools do
      tool :activate_credential, MyClinic.Credential, :activate
    end
  end
  ```
  """

  use Spark.Dsl.Extension,
    verifiers: [AshAgent.Effects.Verifiers.VerifyToolsDeclared]
end
