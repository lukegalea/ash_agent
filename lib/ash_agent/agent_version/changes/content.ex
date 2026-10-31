# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshAgent.AgentVersion.Changes.Content do
  @moduledoc """
  On `create_draft` and `revise_draft`: derives what a version's content implies, never
  taking it from the caller.

    * `toolset` gets each target's current digest (`AshAgent.AgentVersion.Definition.toolset/1`);
      an entry must name its target as a string.
    * `content_hash` is recomputed from the content.
    * On create, `version` is one past the key's highest version in the tenant, read in
      the transaction. Two drafts written at once for one key collide on the
      `[:key, :version]` identity, and the later one is refused.
  """

  use Ash.Resource.Change

  require Ash.Query

  alias AshAgent.AgentVersion.Definition

  @impl true
  def change(changeset, _opts, _context) do
    changeset
    |> derive_toolset()
    |> then(fn changeset ->
      if changeset.valid?, do: hash(changeset), else: changeset
    end)
    |> number()
  end

  defp derive_toolset(changeset) do
    entries = Ash.Changeset.get_attribute(changeset, :toolset) || []

    if Enum.all?(entries, &named?/1) do
      Ash.Changeset.force_change_attribute(changeset, :toolset, Definition.toolset(entries))
    else
      Ash.Changeset.add_error(changeset,
        field: :toolset,
        message:
          "each toolset entry names its target: %{\"target\" => \"Resource.Module.action\"}"
      )
    end
  end

  defp named?(entry) when is_map(entry),
    do: is_binary(Map.get(entry, "target") || Map.get(entry, :target))

  defp named?(_entry), do: false

  defp hash(changeset) do
    content =
      Map.new(AshAgent.AgentVersion.content_attributes(), fn field ->
        {field, Ash.Changeset.get_attribute(changeset, field)}
      end)

    Ash.Changeset.force_change_attribute(
      changeset,
      :content_hash,
      Definition.content_hash(content)
    )
  end

  defp number(%{action_type: :create} = changeset) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      key = Ash.Changeset.get_attribute(changeset, :key)

      latest =
        changeset.resource
        |> Ash.Query.filter(key == ^key)
        |> Ash.Query.sort(version: :desc)
        |> Ash.Query.limit(1)
        |> Ash.Query.select([:version])
        |> Ash.read_one!(tenant: changeset.tenant, authorize?: false)

      Ash.Changeset.force_change_attribute(
        changeset,
        :version,
        ((latest && latest.version) || 0) + 1
      )
    end)
  end

  defp number(changeset), do: changeset
end
