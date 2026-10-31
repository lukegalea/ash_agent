# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshAgent.Validations.Governed do
  @moduledoc """
  Refuses a governed action unless its own invocation is running it.

      update :activate do
        validate {AshAgent.Validations.Governed, invocation: MyClinic.Invocation}
      end

  `invocation` is the host's resource that includes the `AshAgent.Invocation` fragment.

  The executor runs a target with `context.ash_agent` naming the invocation and the lease
  epoch it claimed. A context is only what the caller says, so this validation reads the
  invocation it names, without authorization and in the action's tenant, and requires
  all of:

    * the invocation is `executing`, under the lease epoch the context names;
    * the context carries the secret the executor was given when it claimed that
      lease (`lease_token`), whose digest the claim stored on the row: everything else
      here is known to whoever asked for the invocation, its id, key, epoch and
      arguments, so without it the principal could run the action itself, beside the
      executor, as often as it liked;
    * its `target` is this action;
    * its `args_digest` is the digest, under the host's key (`AshAgent.DigestKey`), of
      the inputs the action was given, with the primary key of the record it acts on
      as the record holds it (for an update or a destroy);
    * the actor is the one it executes as: the host's `principal_of/1`
      (`AshAgent.ExecutionIdentity`) names the invocation's `executing_principal`.

  Anything else fails with `AshAgent.Invocation.Ungoverned`, an invalid-class error,
  whose `reason` says which check failed. The action then does not run.

  It has an `atomic/3` that does the same read, so it leaves an update atomic, and it is
  temporal safe: it reads no clock, and the invocation through Ash. It applies to
  changesets and to generic actions' inputs.
  """

  use Ash.Resource.Validation

  alias AshAgent.{Digest, ExecutionIdentity}
  alias AshAgent.Invocation.{Executor, Info, Target, Ungoverned}

  @impl true
  def init(opts) do
    case opts[:invocation] do
      resource when is_atom(resource) and not is_nil(resource) ->
        {:ok, opts}

      _missing ->
        {:error, "Governed needs `invocation:`, the resource that includes AshAgent.Invocation"}
    end
  end

  @impl true
  def supports(_opts), do: [Ash.Changeset, Ash.ActionInput]

  @impl true
  def describe(_opts), do: [message: "runs only through its invocation", vars: []]

  @impl true
  def temporal_safe?(_opts), do: true

  @impl true
  def validate(subject, opts, context), do: check(subject, opts[:invocation], context.actor)

  @impl true
  def atomic(changeset, opts, context), do: check(changeset, opts[:invocation], context.actor)

  defp check(subject, resource, actor) do
    target = Target.name(subject.resource, subject.action.name)

    with {:ok, id, epoch} <- named(subject),
         {:ok, invocation} <- read(resource, id, subject.tenant),
         :ok <- executing(invocation, epoch),
         :ok <- executor(invocation, subject),
         :ok <- same(invocation.target == target, :other_target),
         :ok <- same_arguments(invocation, resource, inputs(subject)),
         :ok <- same_principal(invocation, resource, actor) do
      :ok
    else
      {:refused, reason} -> {:error, Ungoverned.exception(target: target, reason: reason)}
    end
  end

  defp named(%{context: %{ash_agent: %{invocation_id: id, lease_epoch: epoch}}})
       when is_binary(id) and is_integer(epoch),
       do: {:ok, id, epoch}

  defp named(_subject), do: {:refused, :no_invocation}

  defp read(resource, id, tenant) do
    case Ash.get(resource, id, tenant: tenant, authorize?: false, not_found_error?: false) do
      {:ok, %{} = invocation} -> {:ok, invocation}
      _missing_or_malformed -> {:refused, :unknown_invocation}
    end
  end

  defp executing(%{status: :executing, lease_epoch: epoch}, epoch), do: :ok
  defp executing(_invocation, _epoch), do: {:refused, :not_executing}

  defp executor(%{lease_token_digest: digest}, %{context: %{ash_agent: %{lease_token: token}}})
       when is_binary(digest) and is_binary(token) do
    actual = Executor.token_digest(token)

    same(
      byte_size(actual) == byte_size(digest) and :crypto.hash_equals(actual, digest),
      :not_executor
    )
  end

  defp executor(_invocation, _subject), do: {:refused, :not_executor}

  defp same(true, _reason), do: :ok
  defp same(false, reason), do: {:refused, reason}

  defp same_arguments(%{args_digest: digest} = invocation, resource, inputs)
       when is_binary(digest) do
    case Info.digest_key(resource).digest_key(invocation) do
      {:ok, key} ->
        actual = Digest.hmac_hex(key, inputs)

        same(
          byte_size(actual) == byte_size(digest) and :crypto.hash_equals(actual, digest),
          :other_arguments
        )

      {:error, _reason} ->
        {:refused, :other_arguments}
    end
  rescue
    # Inputs with no JSON form cannot be the ones an invocation was requested with.
    ArgumentError -> {:refused, :other_arguments}
  end

  defp same_arguments(_invocation, _resource, _inputs), do: {:refused, :other_arguments}

  defp same_principal(invocation, resource, actor) do
    case Info.execution_identity(resource).principal_of(actor) do
      {:ok, principal} ->
        same(
          ExecutionIdentity.identity(principal) ==
            ExecutionIdentity.identity(invocation.executing_principal),
          :other_principal
        )

      :error ->
        {:refused, :other_principal}
    end
  end

  # The inputs as the invocation's arguments carry them: what the action was given and,
  # for an update or a destroy, the primary key of the record it acts on. The record's own
  # key wins over any input of the same name, so the digest names the record acted on.
  defp inputs(%Ash.Changeset{action_type: type, data: data, resource: resource} = changeset)
       when type in [:update, :destroy] do
    primary_key =
      resource
      |> Ash.Resource.Info.primary_key()
      |> Map.new(&{Atom.to_string(&1), Map.get(data, &1)})

    Map.merge(stringified(changeset.params), primary_key)
  end

  defp inputs(subject), do: stringified(subject.params)

  defp stringified(params), do: Map.new(params, fn {key, value} -> {to_string(key), value} end)
end
