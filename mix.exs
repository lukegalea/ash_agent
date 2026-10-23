# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshAgent.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/lukegalea/ash_agent"

  @description """
  Governed invocations and durable agent runs for Ash Framework hosts: Spark
  fragments, an effects extension and host behaviours. The host supplies the base
  resource, data layer, tenancy, policies and triggers.
  """

  def project do
    [
      app: :ash_agent,
      version: @version,
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      aliases: aliases(),
      deps: deps(),
      docs: &docs/0,
      description: @description,
      package: package(),
      source_url: @source_url,
      homepage_url: @source_url,
      dialyzer: [
        plt_add_apps: [:mix, :ex_unit],
        plt_file: {:no_warn, "priv/plts/dialyzer.plt"},
        list_unused_filters: true
      ]
    ]
  end

  # test/support holds the test host: a plain Ash.Resource on Postgres that
  # stands in for an application consuming this package.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # The package owns no supervision tree. Workers come from the host's ash_oban
  # triggers and run on the host's Oban instance.
  def application do
    [extra_applications: [:logger]]
  end

  defp package do
    [
      name: :ash_agent,
      licenses: ["MIT"],
      maintainers: ["Luke Galea <luke@ideaforge.org>"],
      files: ~w(lib documentation usage-rules usage-rules.md CHANGELOG.md LICENSE
        LICENSE.license LICENSES README.md mix.exs .formatter.exs),
      links: %{"GitHub" => @source_url}
    ]
  end

  # The dependency list is the package boundary. Nothing from Phoenix, and no
  # application-specific package, may appear here or transitively:
  # scripts/check-boundary.sh fails CI if one does.
  defp deps do
    [
      {:ash, "~> 3.33"},
      {:spark, "~> 2.7"},
      {:ash_ai, "~> 1.3"},
      {:ash_state_machine, "~> 0.2"},
      {:ash_oban, "~> 0.9"},
      # The test host's data layer. A consuming application brings its own.
      {:ash_postgres, "~> 2.14", only: [:dev, :test]},
      # Spark.Formatter, the formatter plugin, needs it.
      {:sourceror, "~> 1.7", only: [:dev, :test]},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:mix_audit, ">= 0.0.0", only: [:dev, :test], runtime: false}
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "main",
      extras: [
        {"README.md", title: "Home"},
        "documentation/topics/what-the-host-supplies.md",
        "documentation/topics/the-boundary.md",
        "CHANGELOG.md"
      ],
      groups_for_extras: [
        Topics: ~r'documentation/topics'
      ]
    ]
  end

  defp aliases do
    # The test host's migrations are generated, never written by hand:
    # `MIX_ENV=test mix ash.codegen <name>` after changing a test resource.
    [credo: "credo --strict"]
  end
end
