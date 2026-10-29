# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshAgent.Invocation.Actions.Invoke do
  @moduledoc """
  The `invoke` action: get by key, or request.

  Two requests are the same request when they share the key and also the target, the
  argument digest, the executing principal and the parent. The same key with any of
  those different is an `AshAgent.Invocation.IdempotencyConflict`, and the existing row
  is neither returned nor changed. It never upserts: an upsert on a logical key can hand
  one caller another caller's row, or overwrite what was approved.

  When concurrent callers all miss the first read, every `request` but one fails on the
  key's identity. Each loser reads the key again, now committed, and applies the same
  comparison, so it returns the winner's row or a conflict.

  The read by key is not authorized: it is the action's own bookkeeping, and the row it
  finds is returned only to a caller with the same principal, which for an automation
  principal includes the person it acts for and its agent.
  """

  use Ash.Resource.Actions.Implementation

  require Ash.Query

  alias AshAgent.ExecutionIdentity
  alias AshAgent.Invocation.{IdempotencyConflict, Info, Lineage}

  @impl true
  def run(input, _opts, context) do
    resource = input.resource
    opts = Ash.Context.to_opts(context)

    request = %{
      target: input.arguments.target,
      args: Map.get(input.arguments, :args) || %{},
      key: Map.get(input.arguments, :key) || "direct:" <> Ash.UUID.generate(),
      parent: Map.get(input.arguments, :parent)
    }

    with {:ok, lineage} <- lineage(request.parent),
         {:ok, principal} <- principal(resource, context) do
      case by_key(resource, request.key, opts) do
        {:ok, nil} -> create(resource, request, lineage, principal, opts)
        {:ok, row} -> same_request(row, request, lineage, principal)
        {:error, error} -> {:error, error}
      end
    end
  end

  defp create(resource, request, lineage, principal, opts) do
    resource
    |> Ash.Changeset.for_create(
      :request,
      %{
        target: request.target,
        args: request.args,
        invocation_key: request.key,
        parent: request.parent
      },
      opts
    )
    |> Ash.create()
    |> case do
      {:ok, row} ->
        {:ok, row}

      {:error, error} ->
        if key_taken?(error) do
          case by_key(resource, request.key, opts) do
            {:ok, %{} = row} -> same_request(row, request, lineage, principal)
            _ -> {:error, error}
          end
        else
          {:error, error}
        end
    end
  end

  defp by_key(resource, key, opts) do
    resource
    |> Ash.Query.filter(invocation_key == ^key)
    |> Ash.read_one(tenant: opts[:tenant], authorize?: false)
  end

  defp same_request(row, request, lineage, principal) do
    if row.target == request.target and
         same_principal?(row.executing_principal, principal) and
         Map.take(row, Lineage.attributes()) == lineage and
         same_args?(row, request.args) do
      {:ok, row}
    else
      {:error, IdempotencyConflict.exception(key: request.key)}
    end
  end

  defp same_args?(%{args_digest: digest} = row, args) when is_binary(digest) do
    case Info.digest_key(row.__struct__).digest_key(row) do
      {:ok, key} -> AshAgent.Digest.hmac_hex(key, args) == digest
      {:error, _reason} -> false
    end
  end

  defp same_args?(_row, _args), do: false

  defp same_principal?(stored, principal) when is_map(stored),
    do: ExecutionIdentity.identity(stored) == ExecutionIdentity.identity(principal)

  defp same_principal?(_stored, _principal), do: false

  defp lineage(parent) do
    case Lineage.from_parent(parent) do
      {:ok, lineage} ->
        {:ok, lineage}

      {:error, message} ->
        {:error, Ash.Error.Changes.InvalidArgument.exception(field: :parent, message: message)}
    end
  end

  defp principal(resource, context) do
    case Info.execution_identity(resource).principal_for(context.actor, Map.from_struct(context)) do
      {:ok, principal} ->
        {:ok, principal}

      {:error, reason} ->
        {:error, AshAgent.Invocation.NoPrincipal.exception(reason: reason)}
    end
  end

  # The key's identity refused the insert: a concurrent request with this key committed
  # first.
  defp key_taken?(%{errors: errors}) when is_list(errors), do: Enum.any?(errors, &key_taken?/1)

  defp key_taken?(%Ash.Error.Changes.InvalidAttribute{field: :invocation_key} = error),
    do:
      Keyword.get(error.private_vars || [], :constraint_type) == :unique or
        error.message =~ "already been taken"

  defp key_taken?(_error), do: false
end
