# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshAgent.AgentVersionTest do
  @moduledoc false
  use AshAgent.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias AshAgent.AgentVersion.{Definition, DefinitionDrift, NotPublished}
  alias AshAgent.Invocation.Target
  alias AshAgent.Test.Agents.{Archivist, LicenceReader}
  alias AshAgent.Test.Domain

  @reader "clinic.licence_reader"

  setup do
    on_exit(fn -> Application.delete_env(:ash_agent, :licence_reader_instructions) end)
  end

  defp change_prompt(text),
    do: Application.put_env(:ash_agent, :licence_reader_instructions, text)

  defp stored(row), do: row |> Map.from_struct() |> Map.drop([:__meta__, :__metadata__])

  defp versions(key),
    do: Domain.list_agent_versions!(query: [filter: [key: key], sort: [version: :asc]])

  # A deploy that changed a tool after the version was written: the stored digest is no
  # longer the target's. Written past the actions, because no action rewrites a toolset's
  # digests.
  defp written_against_earlier_tools(version) do
    toolset =
      Enum.map(version.toolset, fn entry -> Map.put(entry, "target_digest", "earlier") end)

    {1, _} =
      Repo.update_all(
        from(v in "agent_versions", where: v.id == type(^version.id, Ecto.UUID)),
        set: [toolset: toolset]
      )

    Domain.get_agent_version!(version.id)
  end

  describe "register_from_code" do
    test "the first sync writes version 1 as a draft from code" do
      version = Domain.register_agent!(LicenceReader)

      assert %{key: @reader, version: 1, status: :draft, source: :code, output_type: "map"} =
               version

      assert version.limits == %{
               max_steps: 8,
               max_tool_calls: 16,
               deadline: 3_600,
               token_budget: 40_000,
               max_repairs: 2
             }

      {:ok, record} = Target.resolve("AshAgent.Test.CredentialCheck.record")

      assert [
               %{
                 "target" => "AshAgent.Test.CredentialCheck.record",
                 "target_digest" => digest
               },
               %{"target" => "AshAgent.Test.CredentialCheck.mark_verified"}
             ] = version.toolset

      assert digest == Target.digest(record)
      assert version.content_hash == Definition.content_hash(version)
    end

    test "the same code writes no new version" do
      first = Domain.register_agent!(LicenceReader)
      again = Domain.register_agent!(LicenceReader)

      assert again.id == first.id
      assert [%{version: 1}] = versions(@reader)
    end

    test "a changed prompt is the next version, and the earlier one is untouched" do
      first = Domain.register_agent!(LicenceReader)
      change_prompt("Read the licence and say when it lapses.")
      second = Domain.register_agent!(LicenceReader)

      assert second.version == 2
      assert second.instructions == "Read the licence and say when it lapses."
      assert second.content_hash != first.content_hash
      assert stored(Domain.get_agent_version!(first.id)) == stored(first)
      assert [%{version: 1}, %{version: 2}] = versions(@reader)
    end

    test "the same code is a no-op whatever the latest version's status" do
      draft = Domain.register_agent!(LicenceReader)
      published = Domain.publish_agent_version!(draft)

      assert Domain.register_agent!(LicenceReader).id == published.id
    end

    test "a module that is not an agent is refused" do
      assert {:error, %Ash.Error.Invalid{} = error} = Domain.register_agent(Domain)
      assert Exception.message(error) =~ "is not an agent module"
    end

    test "a bad declaration raises when it is read" do
      assert_raise Spark.Options.ValidationError, ~r/required :limits option not found/, fn ->
        AshAgent.Agent.new!(AshAgent.Test.Agents.Broken,
          key: "broken",
          instructions: "x",
          model_profile: "in_zone"
        )
      end
    end
  end

  describe "drafts" do
    test "an authored draft is numbered past the key's latest, and its digests are derived" do
      Domain.register_agent!(LicenceReader)

      draft =
        Domain.create_agent_draft!(%{
          key: @reader,
          instructions: "Read it carefully.",
          model_profile: "in_zone",
          toolset: [%{"target" => "AshAgent.Test.CredentialCheck.record", "target_digest" => "x"}],
          limits: %{max_steps: 1}
        })

      assert %{version: 2, source: :authored} = draft
      assert [%{"target_digest" => digest}] = draft.toolset
      assert digest != "x"
    end

    test "a toolset entry must name its target" do
      assert {:error, %Ash.Error.Invalid{}} =
               Domain.create_agent_draft(%{
                 key: "clinic.unnamed",
                 instructions: "x",
                 model_profile: "in_zone",
                 toolset: [%{"name" => "record"}],
                 limits: %{}
               })
    end

    test "revising a draft recomputes its hash; a published version cannot be revised" do
      draft = Domain.register_agent!(LicenceReader)
      revised = Domain.revise_agent_draft!(draft, %{instructions: "Shorter."})

      assert revised.version == draft.version
      assert revised.content_hash != draft.content_hash
      assert revised.content_hash == Definition.content_hash(revised)

      published = Domain.publish_agent_version!(revised)

      assert {:error, %Ash.Error.Invalid{}} =
               Domain.revise_agent_draft(published, %{instructions: "Again."})
    end
  end

  describe "apply_publish" do
    test "publishes a draft, acting as the requester by default" do
      published = Domain.register_agent!(LicenceReader) |> Domain.publish_agent_version!()

      assert %{status: :published, requesterless: false} = published
      assert published.authority == %{type: :requester}
      assert %DateTime{} = published.published_at
    end

    test "an automation principal is a publish-time choice, and only it may run requesterless" do
      draft = Domain.register_agent!(LicenceReader)

      assert {:error, %Ash.Error.Invalid{} = error} =
               Domain.publish_agent_version(draft, %{requesterless: true})

      assert Exception.message(error) =~ "only an automation authority"

      published =
        Domain.publish_agent_version!(draft, %{
          authority: %{"type" => "automation", "name" => "credential_reader"},
          requesterless: true
        })

      assert published.authority == %{type: :automation, name: "credential_reader"}
      assert published.requesterless
    end

    test "is refused when a toolset target declares no effects" do
      draft = Domain.register_agent!(Archivist)

      assert [%{"target" => "AshAgent.Test.CredentialCheck.archive", "target_digest" => nil}] =
               draft.toolset

      assert {:error, %Ash.Error.Invalid{} = error} = Domain.publish_agent_version(draft)
      assert Exception.message(error) =~ "CredentialCheck.archive declares no effects"
      assert Domain.get_agent_version!(draft.id).status == :draft
    end

    test "is refused when a limit is missing" do
      draft =
        Domain.create_agent_draft!(%{
          key: "clinic.unbounded",
          instructions: "x",
          model_profile: "in_zone",
          limits: %{max_steps: 1, max_tool_calls: 1, deadline: 60, token_budget: 10}
        })

      assert {:error, error} = Domain.publish_agent_version(draft)
      assert Exception.message(error) =~ "limits: max_repairs is not set"
    end

    test "is refused when a tool changed since the draft was written" do
      draft = Domain.register_agent!(LicenceReader) |> written_against_earlier_tools()

      assert {:error, error} = Domain.publish_agent_version(draft)
      assert Exception.message(error) =~ "has changed since this version was written"
    end

    test "a published version is published once" do
      published = Domain.register_agent!(LicenceReader) |> Domain.publish_agent_version!()
      assert {:error, _not_a_draft} = Domain.publish_agent_version(published)
    end
  end

  describe "pinning" do
    test "a run pinned to version 1 carries on after version 2 is published" do
      v1 = Domain.register_agent!(LicenceReader) |> Domain.publish_agent_version!()
      change_prompt("Read the licence and say when it lapses.")
      v2 = Domain.register_agent!(LicenceReader) |> Domain.publish_agent_version!()

      assert Domain.latest_published_agent_version!(@reader).id == v2.id

      pinned = Domain.get_agent_version!(v1.id)
      assert {:ok, ^pinned} = Definition.check_pinned(pinned)
      assert pinned.status == :published
      assert pinned.instructions == v1.instructions
    end

    test "a retired version starts nothing new, and a run pinned to it carries on" do
      v1 = Domain.register_agent!(LicenceReader) |> Domain.publish_agent_version!()
      retired = Domain.retire_agent_version!(v1)

      assert retired.status == :retired
      assert {:error, _none} = Domain.latest_published_agent_version(@reader)
      assert {:ok, _} = Definition.check_pinned(retired)
    end

    test "a pinned version whose tool changed is definition drift" do
      pinned =
        Domain.register_agent!(LicenceReader)
        |> Domain.publish_agent_version!()
        |> written_against_earlier_tools()

      assert {:error, %DefinitionDrift{reason: :definition_drift, drifted: drifted} = error} =
               Definition.check_pinned(pinned)

      assert [
               %{"target" => "AshAgent.Test.CredentialCheck.record", "pinned" => "earlier"},
               %{"target" => "AshAgent.Test.CredentialCheck.mark_verified"}
             ] = drifted

      assert Exception.message(error) =~ "definition_drift"
    end

    test "a pinned version whose tool no longer resolves is definition drift" do
      v1 = Domain.register_agent!(Archivist)

      {1, _} =
        Repo.update_all(
          from(v in "agent_versions", where: v.id == type(^v1.id, Ecto.UUID)),
          set: [status: "published"]
        )

      assert {:error, %DefinitionDrift{drifted: [%{"current" => nil}]}} =
               Definition.check_pinned(Domain.get_agent_version!(v1.id))
    end

    test "a draft cannot be pinned" do
      draft = Domain.register_agent!(LicenceReader)
      assert {:error, %NotPublished{status: :draft}} = Definition.check_pinned(draft)
    end
  end
end
