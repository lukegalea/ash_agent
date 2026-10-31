# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshAgent.AgentVersion.Actions.RegisterFromCode do
  @moduledoc """
  The `register_from_code` action: the code sync for one agent module.

  The declaration's content (`AshAgent.Agent.content/1`, with each target's current
  digest) is hashed and compared with the key's latest version in the tenant. The same
  hash returns that version, and nothing is written, whatever its status: running the
  sync again with the same code is a no-op. A different hash writes a draft numbered one
  past it, with `source: :code`. A changed tool's input schema or effects declaration
  changes the hash too, so the version a sync writes always records what the code now
  offers.

  `register/3` is the same rule for content from anywhere, such as a host copying a
  shared baseline into a tenant.
  """

  use Ash.Resource.Actions.Implementation

  require Ash.Query

  alias AshAgent.AgentVersion.Definition

  @impl true
  def run(input, _opts, context) do
    with {:ok, agent} <- declaration(input.arguments.agent) do
      register(
        input.resource,
        Map.put(AshAgent.Agent.content(agent), :source, :code),
        Ash.Context.to_opts(context)
      )
    end
  end

  @doc """
  The latest version of `content.key` in `opts[:tenant]` when its content hash is
  `content`'s, otherwise a new draft of `content` numbered one past it. `content` holds
  the content attributes and `key`, and may hold `source` and `baseline_id`, which are
  recorded on a new draft as given. `opts` are the caller's (`actor`, `tenant`,
  `authorize?`, `context`), and the draft is written as the caller.

  Two registrations of new content for one key at once: one writes the next version,
  the other finds that number taken, reads again and returns the winner when it holds
  the same content.
  """
  @spec register(Ash.Resource.t(), map(), keyword()) ::
          {:ok, Ash.Resource.record()} | {:error, term()}
  def register(resource, content, opts) do
    hash =
      content
      |> Map.update(:toolset, [], &Definition.toolset/1)
      |> Definition.content_hash()

    case latest(resource, content.key, opts) do
      {:ok, %{content_hash: ^hash} = version} -> {:ok, version}
      {:ok, _other_or_none} -> create(resource, content, hash, opts)
      {:error, error} -> {:error, error}
    end
  end

  defp create(resource, content, hash, opts) do
    resource
    |> Ash.Changeset.for_create(
      :create_draft,
      Map.take(content, [:key | AshAgent.AgentVersion.content_attributes()]),
      opts
    )
    |> Ash.Changeset.force_change_attributes(Map.take(content, [:source, :baseline_id]))
    |> Ash.create()
    |> case do
      {:ok, version} ->
        {:ok, version}

      {:error, error} ->
        with true <- number_taken?(error),
             {:ok, %{content_hash: ^hash} = version} <- latest(resource, content.key, opts) do
          {:ok, version}
        else
          _ -> {:error, error}
        end
    end
  end

  # The key's own bookkeeping: read without authorization, in the caller's tenant.
  defp latest(resource, key, opts) do
    resource
    |> Ash.Query.filter(key == ^key)
    |> Ash.Query.sort(version: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read_one(tenant: opts[:tenant], authorize?: false)
  end

  defp declaration(module) do
    case AshAgent.Agent.declaration(module) do
      {:ok, agent} ->
        {:ok, agent}

      {:error, message} ->
        {:error, Ash.Error.Changes.InvalidArgument.exception(field: :agent, message: message)}
    end
  end

  defp number_taken?(%{errors: errors}) when is_list(errors),
    do: Enum.any?(errors, &number_taken?/1)

  defp number_taken?(%Ash.Error.Changes.InvalidAttribute{field: field} = error)
       when field in [:key, :version],
       do:
         Keyword.get(error.private_vars || [], :constraint_type) == :unique or
           error.message =~ "already been taken"

  defp number_taken?(_error), do: false
end
