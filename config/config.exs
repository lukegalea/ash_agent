# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

import Config

# This config exists for the package's own dev and test runs. It is not shipped
# (`files:` in mix.exs excludes config/); a consuming application configures its
# own repo, domains and Oban.

# Required since ash 3.33: an application compiling its own resources makes an
# explicit choice about how string length constraints count. Codepoints is how
# SQL counts length, so Elixir-side validation agrees with the data layer.
config :ash, default_string_length_count: :codepoints

if config_env() == :test do
  import_config "test.exs"
end
