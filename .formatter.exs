# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

# The `invocation` section's options, here and for a host that imports this
# package's formatter rules (`import_deps: [:ash_agent]`).
locals_without_parens = [execution_identity: 1, digest_key: 1]

[
  locals_without_parens: locals_without_parens,
  export: [locals_without_parens: locals_without_parens],
  import_deps: [:ash, :ash_postgres, :ash_state_machine, :ash_oban],
  plugins: [Spark.Formatter],
  inputs: [
    "{mix,.formatter}.exs",
    "{config,lib,test,scripts}/**/*.{ex,exs}"
  ]
]
