# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defprotocol AshAgent.FailureClass do
  @moduledoc """
  How an error a host's own code raises classifies an invocation's failure.

  An invocation's target can fail with errors the package does not know: a timeout
  from an HTTP client, a provider's rate limit. Implement this protocol for such an
  error type, once, and every invocation whose target returns it is classified the
  same way (`AshAgent.Invocation.Failure`):

      defimpl AshAgent.FailureClass, for: MyClinic.Gateway.Error do
        def classify(%{reason: :rate_limited}), do: {:transient, "rate_limited"}
        def classify(%{reason: :timeout}), do: {:indeterminate, "timeout"}
        def classify(%{reason: reason}), do: {:permanent, to_string(reason)}
      end

  Return one of:

    * `{:transient, code}`: the call did not take effect, and may succeed later;
    * `{:indeterminate, code}`: the call may have taken effect and its acknowledgement
      was lost (a timeout after sending, a dropped connection). Never return
      `:transient` for this: an outside effect that is not idempotent would happen twice;
    * `{class, code}` for any other failure class: `:denied`, `:rejected`, `:business`,
      `:permanent`, `:timeout` or `:budget`;
    * `:unclassified`, to let the error's place in the Ash error it is wrapped in decide.

  Everything else falls back to `:unclassified`.
  """

  @fallback_to_any true

  @typedoc "A failure class, or `:indeterminate` for a call whose effect is unknown."
  @type class ::
          :denied
          | :rejected
          | :business
          | :transient
          | :permanent
          | :timeout
          | :budget
          | :indeterminate

  @doc "Classifies `error`."
  @spec classify(t()) :: {class(), String.t()} | :unclassified
  def classify(error)
end

defimpl AshAgent.FailureClass, for: Any do
  def classify(_error), do: :unclassified
end
