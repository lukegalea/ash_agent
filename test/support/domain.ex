# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshAgent.Test.Domain do
  @moduledoc """
  The test host's domain.

  The test host plays the part of an application that consumes this package. It
  uses plain `Ash.Resource` with no base resource of its own, so the suite shows
  that nothing in the package depends on any particular host.
  """

  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshAgent.Test.Clinician do
      define :register_clinician, action: :create
      define :list_clinicians, action: :read
    end
  end
end
