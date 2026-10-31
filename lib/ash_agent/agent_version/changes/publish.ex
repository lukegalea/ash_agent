# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshAgent.AgentVersion.Changes.Publish do
  @moduledoc """
  On `apply_publish`: refuses a draft that cannot be published
  (`AshAgent.AgentVersion.Definition.publish_problems/1`), and records the publish-time
  choices.

    * `authority` is `%{"type" => "requester"}` (the default: runs act as the person who
      asked) or `%{"type" => "automation", "name" => principal}`. Whether the host knows
      the principal is the host's to check.
    * `requesterless` may be true only with an automation authority: a run with no person
      asking has no requester to act as.

  The checks run in the update's transaction, on the draft as it is read there, so a
  revision committed after the publish was asked for is what they see.
  """

  use Ash.Resource.Change

  alias AshAgent.AgentVersion.Definition

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      authority = Ash.Changeset.get_argument(changeset, :authority)
      requesterless = Ash.Changeset.get_argument(changeset, :requesterless)

      with {:ok, authority} <- authority(authority),
           :ok <- requesterless(authority, requesterless),
           [] <- Definition.publish_problems(changeset.data) do
        Ash.Changeset.force_change_attributes(changeset, %{
          authority: authority,
          requesterless: requesterless
        })
      else
        {:error, field, message} ->
          Ash.Changeset.add_error(changeset, field: field, message: message)

        problems when is_list(problems) ->
          Enum.reduce(problems, changeset, fn problem, changeset ->
            Ash.Changeset.add_error(changeset, message: "cannot publish: #{problem}")
          end)
      end
    end)
  end

  defp authority(authority) do
    case Map.new(authority, fn {key, value} -> {to_string(key), value} end) do
      %{"type" => type} = authority when type in ["requester", :requester] ->
        if is_nil(authority["name"]),
          do: {:ok, %{type: :requester}},
          else: {:error, :authority, "a requester authority names no principal"}

      %{"type" => type, "name" => name}
      when type in ["automation", :automation] and is_binary(name) and name != "" ->
        {:ok, %{type: :automation, name: name}}

      _other ->
        {:error, :authority,
         ~s(is %{"type" => "requester"} or %{"type" => "automation", "name" => principal})}
    end
  end

  defp requesterless(%{type: :requester}, true),
    do: {:error, :requesterless, "only an automation authority may run with no requester"}

  defp requesterless(_authority, _requesterless), do: :ok
end
