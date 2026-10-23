# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

[
  import_deps: [:ash, :ash_postgres, :ash_state_machine, :ash_oban],
  plugins: [Spark.Formatter],
  inputs: [
    "{mix,.formatter}.exs",
    "{config,lib,test,scripts}/**/*.{ex,exs}"
  ]
]
