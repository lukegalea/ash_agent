# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshAgent.Invocation.Dispatch do
  @moduledoc """
  What a target returns when it handed its work to someone else and the outcome comes
  later: an outside service that answers by callback, a person, a process it started.

      action :send_referral, :struct do
        constraints instance_of: AshAgent.Invocation.Dispatch

        run fn input, context ->
          {:ok, ref} = Lab.send(input.arguments, context.ash_agent.invocation_key)

          {:ok,
           AshAgent.Invocation.Dispatch.new(
             effect_system: "lab",
             effect_ref: ref,
             deadline_at: DateTime.add(DateTime.utc_now(), 2, :day)
           )}
        end
      end

  The invocation becomes `dispatched`: it holds no lease, and `deadline_at` bounds the
  wait. The outcome arrives through `complete_external`; a deadline that passes first is
  settled by `reconcile` (see `AshAgent.Invocation.Reconciler`).
  """

  @enforce_keys [:effect_ref, :deadline_at]
  defstruct [:effect_system, :effect_ref, :deadline_at]

  @type t :: %__MODULE__{
          effect_system: String.t() | nil,
          effect_ref: String.t(),
          deadline_at: DateTime.t()
        }

  @doc "A dispatch. `effect_ref` and `deadline_at` are required."
  @spec new(keyword()) :: t()
  def new(fields), do: struct!(__MODULE__, fields)
end
