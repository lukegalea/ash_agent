# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

# The package boundary, checked. Run through scripts/check-boundary.sh, which
# runs it as `mix run --no-start scripts/check_boundary.exs`.
#
# Two checks, both of which must pass:
#
# 1. Dependencies. No Phoenix package and no application-specific package may
#    reach this package's dependency tree, with one recorded exception (below).
#
# 2. References. No module compiled from this repository (lib/ and, in the test
#    environment, the test host in test/support) may refer to a module whose
#    name starts with Phoenix, AshEnterprise or AshBpmn. The check reads the
#    Erlang abstract code in each module's debug info and collects every atom in
#    it, so remote calls, struct names, module names passed as values and module
#    names inside literal data are all seen. A macro that expands to nothing
#    naming its own module leaves no trace in the compiled code and is not seen.
#
# `--self-test` runs the dependency check against a synthetic tree that must
# fail, and exits non-zero if it does not.

defmodule AshAgent.BoundaryCheck do
  @moduledoc false

  @forbidden_prefixes ["Phoenix", "AshEnterprise", "AshBpmn"]
  @forbidden_packages [~r/^phoenix/, ~r/^ash_enterprise$/, ~r/^ash_bpmn$/]

  # ash_ai depends on ash_json_api, which depends on phoenix (not optional), so
  # depending on ash_ai brings Phoenix into the tree. This package uses ash_ai
  # for its tool loop and never refers to Phoenix itself; check 2 enforces the
  # second half. Any other path to a Phoenix package fails, including a new
  # one through ash_json_api (phoenix_live_view, say).
  @allowed_edges [{:ash_json_api, :phoenix}]

  def run(argv) do
    case argv do
      ["--self-test"] -> self_test()
      [] -> check()
    end
  end

  defp check do
    dependency_problems = dependency_problems(Mix.Project.deps_tree(), top_level_deps())
    reference_problems = reference_problems(own_modules())

    Enum.each(dependency_problems ++ reference_problems, &IO.puts(:stderr, &1))

    case {dependency_problems, reference_problems} do
      {[], []} ->
        IO.puts("boundary: ok (dependencies and references)")

      _ ->
        IO.puts(:stderr, "boundary: FAILED")
        System.halt(1)
    end
  end

  defp self_test do
    tree = %{
      ash: [],
      ash_ai: [:ash_json_api],
      ash_json_api: [:phoenix],
      phoenix: [:phoenix_pubsub],
      phoenix_pubsub: [],
      ash_bpmn: [:phoenix_live_view],
      phoenix_live_view: [:phoenix]
    }

    allowed =
      dependency_problems(
        Map.take(tree, [:ash, :ash_ai, :ash_json_api, :phoenix, :phoenix_pubsub]),
        [:ash, :ash_ai]
      )

    forbidden = dependency_problems(tree, [:ash, :ash_ai, :ash_bpmn])

    cond do
      allowed != [] ->
        IO.puts(:stderr, "self-test: the allowed ash_ai path was reported: #{inspect(allowed)}")
        System.halt(1)

      not Enum.any?(forbidden, &String.contains?(&1, "ash_bpmn")) or
          not Enum.any?(forbidden, &String.contains?(&1, "phoenix_live_view")) ->
        IO.puts(:stderr, "self-test: a forbidden path was not reported: #{inspect(forbidden)}")
        System.halt(1)

      true ->
        IO.puts("self-test: ok (the dependency check reports ash_bpmn and phoenix_live_view)")
    end
  end

  @doc false
  def dependency_problems(tree, roots) do
    tree
    |> reachable(roots)
    |> Enum.filter(fn {app, _path} -> forbidden_package?(app) end)
    |> Enum.sort()
    |> Enum.map(fn {app, path} ->
      "dependency: #{app} is in the dependency tree (#{Enum.join(Enum.reverse(path), " -> ")})"
    end)
  end

  # Breadth-first walk from the top-level dependencies, skipping allowed edges.
  # Returns the first path found to each reachable app.
  defp reachable(tree, roots) do
    queue = :queue.from_list(Enum.map(roots, &{&1, [&1]}))
    walk(tree, queue, %{})
  end

  defp walk(tree, queue, seen) do
    case :queue.out(queue) do
      {:empty, _} ->
        seen

      {{:value, {app, _path}}, rest} when is_map_key(seen, app) ->
        walk(tree, rest, seen)

      {{:value, {app, path}}, rest} ->
        children =
          tree
          |> Map.get(app, [])
          |> Enum.reject(&({app, &1} in @allowed_edges))
          |> Enum.map(&{&1, [&1 | path]})

        walk(tree, Enum.reduce(children, rest, &:queue.in/2), Map.put(seen, app, path))
    end
  end

  defp forbidden_package?(app) do
    name = Atom.to_string(app)
    Enum.any?(@forbidden_packages, &Regex.match?(&1, name))
  end

  defp top_level_deps do
    Enum.map(Mix.Project.config()[:deps], &elem(&1, 0))
  end

  defp own_modules do
    app = Mix.Project.config()[:app]
    :ok = ensure_loaded(app)
    {:ok, modules} = :application.get_key(app, :modules)
    modules
  end

  defp ensure_loaded(app) do
    case Application.load(app) do
      :ok -> :ok
      {:error, {:already_loaded, ^app}} -> :ok
    end
  end

  @doc false
  def reference_problems(modules) do
    for module <- modules,
        atom <- referenced_atoms(module),
        forbidden_reference?(atom) do
      "reference: #{inspect(module)} refers to #{inspect(atom)}"
    end
    |> Enum.uniq()
  end

  defp referenced_atoms(module) do
    path = :code.which(module)

    case :beam_lib.chunks(path, [:debug_info]) do
      {:ok, {^module, [debug_info: {:debug_info_v1, backend, data}]}} ->
        {:ok, forms} = backend.debug_info(:erlang_v1, module, data, [])
        forms |> collect_atoms(MapSet.new()) |> MapSet.to_list()

      other ->
        raise "cannot read the debug info of #{inspect(module)}: #{inspect(other)}"
    end
  end

  defp collect_atoms(term, acc) when is_atom(term), do: MapSet.put(acc, term)
  defp collect_atoms(term, acc) when is_list(term), do: Enum.reduce(term, acc, &collect_atoms/2)

  defp collect_atoms(term, acc) when is_tuple(term),
    do: term |> Tuple.to_list() |> collect_atoms(acc)

  defp collect_atoms(term, acc) when is_map(term),
    do: term |> Map.to_list() |> collect_atoms(acc)

  defp collect_atoms(_term, acc), do: acc

  # A prefix, not a namespace: `AshEnterprise` also rules out `AshEnterpriseWeb`.
  defp forbidden_reference?(atom) do
    name = Atom.to_string(atom)
    Enum.any?(@forbidden_prefixes, &String.starts_with?(name, "Elixir." <> &1))
  end
end

AshAgent.BoundaryCheck.run(System.argv())
