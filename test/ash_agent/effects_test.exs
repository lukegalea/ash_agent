# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshAgent.EffectsTest do
  @moduledoc false
  use ExUnit.Case, async: true

  import Spark.Test

  alias AshAgent.Effects.{Effect, Info}
  alias AshAgent.Test.Credential
  alias Spark.Error.DslError

  describe "Info" do
    test "reads a declaration by action name or action struct" do
      activate = Info.effect(Credential, :activate)

      assert %Effect{
               kind: :edit,
               read_only?: false,
               destructive?: false,
               idempotent?: true,
               open_world?: true,
               approval: :four_eyes,
               approver_role: :credentialing_committee,
               approval_expires_in: [days: 3],
               intent: :execute,
               reconcile_with: :lookup_activation,
               preconditions: [:clinician_id]
             } = activate

      assert Info.effect(Credential, Ash.Resource.Info.action(Credential, :activate)) == activate
      assert Enum.map(Info.effects(Credential), & &1.name) == [:read, :activate]
    end

    test "an undeclared action answers nil" do
      assert Info.effect(Credential, :suspend) == nil
      refute Info.declared?(Credential, :suspend)
      assert Info.declared?(Credential, :read)
    end

    test "a resource without the extension declares nothing" do
      assert Info.effects(AshAgent.Test.Clinician) == []
      refute Info.uses_effects?(AshAgent.Test.Clinician)
      assert Info.uses_effects?(Credential)
    end

    test "hints left out take MCP's defaults, and approval defaults to :none" do
      defaults = %Effect{name: :x, kind: :other}
      declared = Info.effect(Credential, :read)

      assert {defaults.destructive?, defaults.idempotent?, defaults.open_world?} ==
               {true, false, true}

      refute defaults.read_only?
      assert declared.destructive?
      assert declared.approval == :none
      assert declared.preconditions == []
    end

    test "to_map/1 is a string-keyed snapshot of the declaration" do
      assert Effect.to_map(Info.effect(Credential, :activate)) == %{
               "action" => "activate",
               "kind" => "edit",
               "read_only" => false,
               "destructive" => false,
               "idempotent" => true,
               "open_world" => true,
               "approval" => "four_eyes",
               "approver_role" => "credentialing_committee",
               "approval_expires_in" => %{"days" => 3},
               "intent" => "execute",
               "reconcile_with" => "lookup_activation",
               "preconditions" => ["clinician_id"]
             }
    end
  end

  describe "compile-time verification" do
    # Spark reports verifier errors as compile diagnostics, which is what fails a
    # `mix compile --warnings-as-errors` build. This compiles a real source file
    # the way mix does and reads the diagnostics back.
    @tag :tmp_dir
    test "read_only? on a non-read action fails the build", %{tmp_dir: tmp_dir} do
      source = Path.join(tmp_dir, "read_only_update.ex")

      File.write!(source, """
      defmodule AshAgent.EffectsTest.CompiledReadOnlyUpdate do
        use Ash.Resource, domain: nil, extensions: [AshAgent.Effects]

        effects do
          action :suspend, kind: :edit, read_only?: true
        end

        actions do
          update :suspend
        end

        attributes do
          uuid_primary_key :id
        end
      end
      """)

      {{:ok, modules, diagnostics}, _stderr} = compile(source)
      assert AshAgent.EffectsTest.CompiledReadOnlyUpdate in modules

      # Verification-phase diagnostics: `mix compile --warnings-as-errors`
      # fails on any of them.
      assert [%{severity: :warning, message: message}] =
               Enum.filter(diagnostics.runtime_warnings, &(&1.message =~ "Spark.Error.DslError"))

      assert message =~ "declares :suspend read_only?: true, but it is a :update action"
    end

    test "read_only? on a non-read action fails compilation" do
      error =
        assert_dsl_error %DslError{path: [:effects, :action, :suspend]} do
          defmodule Elixir.AshAgent.EffectsTest.ReadOnlyUpdate do
            use Ash.Resource, domain: nil, extensions: [AshAgent.Effects]

            effects do
              action :suspend, kind: :edit, read_only?: true
            end

            actions do
              update :suspend
            end

            attributes do
              uuid_primary_key :id
            end
          end
        end

      assert error.message =~ "read_only?: true, but it is a :update action"
    end

    test "read_only? on a generic action fails compilation" do
      error =
        assert_dsl_error %DslError{} do
          defmodule Elixir.AshAgent.EffectsTest.ReadOnlyGeneric do
            use Ash.Resource, domain: nil, extensions: [AshAgent.Effects]

            effects do
              action :lookup, kind: :search, read_only?: true
            end

            actions do
              action :lookup, :boolean do
                run fn _input, _context -> {:ok, true} end
              end
            end
          end
        end

      assert error.message =~ "it is a :action action"
    end

    test "a declaration for an action the resource does not have fails compilation" do
      error =
        assert_dsl_error %DslError{} do
          defmodule Elixir.AshAgent.EffectsTest.UnknownAction do
            use Ash.Resource, domain: nil, extensions: [AshAgent.Effects]

            effects do
              action :archive, kind: :edit
            end

            actions do
              defaults [:read]
            end

            attributes do
              uuid_primary_key :id
            end
          end
        end

      assert error.message =~ ":archive, which is not an action"
    end

    test "four-eyes approval needs an approver role" do
      error =
        assert_dsl_error %DslError{} do
          defmodule Elixir.AshAgent.EffectsTest.FourEyesNoRole do
            use Ash.Resource, domain: nil, extensions: [AshAgent.Effects]

            effects do
              action :suspend, kind: :edit, approval: :four_eyes
            end

            actions do
              update :suspend
            end

            attributes do
              uuid_primary_key :id
            end
          end
        end

      assert error.message =~ "approval: :four_eyes without an approver_role"
    end

    test "an approver role or expiry without an approval fails compilation" do
      errors =
        dsl_errors do
          defmodule Elixir.AshAgent.EffectsTest.RoleNoApproval do
            use Ash.Resource, domain: nil, extensions: [AshAgent.Effects]

            effects do
              action :suspend,
                kind: :edit,
                approver_role: :committee,
                approval_expires_in: [hours: 4]
            end

            actions do
              update :suspend
            end

            attributes do
              uuid_primary_key :id
            end
          end
        end

      assert [{AshAgent.EffectsTest.RoleNoApproval, [_, _] = errors}] = errors
      assert Enum.all?(errors, &(&1.message =~ "with approval: :none"))
    end

    test "reconcile_with must name a read or generic action" do
      errors =
        dsl_errors do
          defmodule Elixir.AshAgent.EffectsTest.BadReconcile do
            use Ash.Resource, domain: nil, extensions: [AshAgent.Effects]

            effects do
              action :activate, kind: :edit, reconcile_with: :suspend
              action :suspend, kind: :edit, reconcile_with: :missing
            end

            actions do
              update :activate
              update :suspend
            end

            attributes do
              uuid_primary_key :id
            end
          end
        end

      assert [{_module, [update, missing]}] = errors
      assert update.message =~ "a :update action"
      assert missing.message =~ ":missing, which is not an action"
    end

    test "preconditions must be inputs of the action" do
      error =
        assert_dsl_error %DslError{} do
          defmodule Elixir.AshAgent.EffectsTest.BadPrecondition do
            use Ash.Resource, domain: nil, extensions: [AshAgent.Effects]

            effects do
              action :activate, kind: :edit, preconditions: [:clinician_id]
            end

            actions do
              update :activate
            end

            attributes do
              uuid_primary_key :id
            end
          end
        end

      assert error.message =~ "precondition :clinician_id, which is not an input"
    end

    test "an action is declared at most once" do
      error =
        assert_dsl_error %DslError{} do
          defmodule Elixir.AshAgent.EffectsTest.Twice do
            use Ash.Resource, domain: nil, extensions: [AshAgent.Effects]

            effects do
              action :read, kind: :read
              action :read, kind: :search
            end

            actions do
              defaults [:read]
            end

            attributes do
              uuid_primary_key :id
            end
          end
        end

      assert error.message =~ "duplicate"
    end

    test "a valid declaration compiles cleanly" do
      refute_dsl_errors do
        defmodule Elixir.AshAgent.EffectsTest.Valid do
          use Ash.Resource, domain: nil, extensions: [AshAgent.Effects]

          effects do
            action :read, kind: :read, read_only?: true, open_world?: false
            action :activate, kind: :edit, approval: :confirm
          end

          actions do
            defaults [:read]
            update :activate
          end

          attributes do
            uuid_primary_key :id
          end
        end
      end
    end
  end

  describe "AshAgent.Effects.Domain" do
    test "an undeclared tool on a resource that declares effects fails compilation" do
      error =
        assert_dsl_error %DslError{path: [:tools, :suspend_credential]} do
          defmodule Elixir.AshAgent.EffectsTest.GovernedTools do
            use Ash.Domain,
              extensions: [AshAi, AshAgent.Effects.Domain],
              validate_config_inclusion?: false

            resources do
              resource AshAgent.Test.Credential
            end

            tools do
              tool(:list_credentials, AshAgent.Test.Credential, :read)
              tool(:activate_credential, AshAgent.Test.Credential, :activate)
              tool(:suspend_credential, AshAgent.Test.Credential, :suspend)
            end
          end
        end

      assert error.message =~ "AshAgent.Test.Credential.suspend"
      assert error.message =~ "declares effects"
    end

    test "an undeclared tool on a resource without the extension warns" do
      {message, _location} =
        assert_dsl_warning do
          defmodule Elixir.AshAgent.EffectsTest.UndeclaredTools do
            use Ash.Domain,
              extensions: [AshAi, AshAgent.Effects.Domain],
              validate_config_inclusion?: false

            resources do
              resource AshAgent.Test.Clinician
            end

            tools do
              tool(:list_clinicians, AshAgent.Test.Clinician, :read)
            end
          end
        end

      assert message =~ "tool :list_clinicians exposes AshAgent.Test.Clinician.read"
    end

    test "declared tools compile without errors or warnings" do
      refute_dsl_warnings do
        refute_dsl_errors do
          defmodule Elixir.AshAgent.EffectsTest.DeclaredTools do
            use Ash.Domain,
              extensions: [AshAi, AshAgent.Effects.Domain],
              validate_config_inclusion?: false

            resources do
              resource AshAgent.Test.Credential
            end

            tools do
              tool(:list_credentials, AshAgent.Test.Credential, :read)
              tool(:activate_credential, AshAgent.Test.Credential, :activate)
            end
          end
        end
      end
    end
  end

  defp compile(source) do
    ExUnit.CaptureIO.with_io(:stderr, fn ->
      Kernel.ParallelCompiler.compile([source], return_diagnostics: true)
    end)
  end
end
