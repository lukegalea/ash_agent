# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshAgent.Execution.Status do
  @moduledoc """
  The six statuses every execution entry shares, and how the package's own lifecycles
  map to them.

  An invocation, a run, an approval task and a process instance each have a lifecycle of
  their own. A reader comparing them needs one vocabulary, and a small one:

    * `:waiting`: not started, or paused until something happens (`blocked_on` says
      what);
    * `:running`: under way now;
    * `:succeeded`: finished as asked;
    * `:failed`: finished without doing what was asked;
    * `:cancelled`: stopped by a person or by a decision not to go ahead;
    * `:uncertain`: it may or may not have happened. An outside call whose answer was
      lost is uncertain, and so is any status this module does not know: a status it
      cannot place is never read as a success.

  `invocation/1` and `run/1` take a row of a resource that includes `AshAgent.Invocation`
  or `AshAgent.Run`, or its status, and answer `{status, blocked_on}`.
  """

  @type t :: :waiting | :running | :succeeded | :failed | :cancelled | :uncertain

  @statuses [:waiting, :running, :succeeded, :failed, :cancelled, :uncertain]

  @doc "The six statuses."
  @spec statuses() :: [t()]
  def statuses, do: @statuses

  @doc """
  `status` when it is one of the six, else `:uncertain`.

      iex> AshAgent.Execution.Status.coerce(:succeeded)
      :succeeded

      iex> AshAgent.Execution.Status.coerce("succeeded")
      :uncertain

      iex> AshAgent.Execution.Status.coerce(nil)
      :uncertain
  """
  @spec coerce(term()) :: t()
  def coerce(status) when status in @statuses, do: status
  def coerce(_status), do: :uncertain

  @doc """
  An invocation's status, from its row or its `status`.

    * `requested`: `:waiting`, not yet routed;
    * `awaiting_approval`: `:waiting` on `:approval`;
    * `request_info`: `:waiting` on `:requester`, asked for more before a decision;
    * `ready`: `:waiting` on `:queue`;
    * `executing`: `:running`;
    * `dispatched`: `:running`, on `:external`: sent, its completion not yet reported;
    * `succeeded` and `failed`: themselves;
    * `outcome_unknown`: `:uncertain`;
    * `rejected`: `:cancelled`, decided against by its approver;
    * `stale`: `:failed`: what was approved or asked for changed, and it will not run;
    * `cancelled`: `:cancelled`;
    * anything else, `nil` included: `:uncertain`.

      iex> AshAgent.Execution.Status.invocation(:awaiting_approval)
      {:waiting, :approval}

      iex> AshAgent.Execution.Status.invocation(:request_info)
      {:waiting, :requester}

      iex> AshAgent.Execution.Status.invocation(:outcome_unknown)
      {:uncertain, nil}
  """
  @spec invocation(map() | atom() | nil) :: {t(), atom() | nil}
  def invocation(%{status: status}), do: invocation(status)
  def invocation(:requested), do: {:waiting, nil}
  def invocation(:awaiting_approval), do: {:waiting, :approval}
  def invocation(:request_info), do: {:waiting, :requester}
  def invocation(:ready), do: {:waiting, :queue}
  def invocation(:executing), do: {:running, nil}
  def invocation(:dispatched), do: {:running, :external}
  def invocation(:succeeded), do: {:succeeded, nil}
  def invocation(:failed), do: {:failed, nil}
  def invocation(:outcome_unknown), do: {:uncertain, nil}
  def invocation(:rejected), do: {:cancelled, nil}
  def invocation(:stale), do: {:failed, nil}
  def invocation(:cancelled), do: {:cancelled, nil}
  def invocation(_unknown), do: {:uncertain, nil}

  @doc """
  An agent run's status, from its row or its `status`: `queued` is `:waiting` on
  `:queue`, `waiting` is `:waiting` on the row's `blocked_on`, `running` is `:running`,
  `completed` is `:succeeded`, `failed` and `cancelled` are themselves, and anything
  else is `:uncertain`.

      iex> AshAgent.Execution.Status.run(%{status: :waiting, blocked_on: :tools})
      {:waiting, :tools}

      iex> AshAgent.Execution.Status.run(:completed)
      {:succeeded, nil}
  """
  @spec run(map() | atom() | nil) :: {t(), atom() | nil}
  def run(%{status: :waiting} = row), do: {:waiting, Map.get(row, :blocked_on)}
  def run(%{status: status}), do: run(status)
  def run(:queued), do: {:waiting, :queue}
  def run(:waiting), do: {:waiting, nil}
  def run(:running), do: {:running, nil}
  def run(:completed), do: {:succeeded, nil}
  def run(:failed), do: {:failed, nil}
  def run(:cancelled), do: {:cancelled, nil}
  def run(_unknown), do: {:uncertain, nil}
end
