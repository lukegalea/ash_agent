# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshAgent.TestHostTest do
  @moduledoc false
  use AshAgent.DataCase, async: true

  alias AshAgent.Test.Domain

  test "the test host writes to and reads from Postgres" do
    clinician =
      Domain.register_clinician!(%{
        name: "Dr. Ada Moss",
        license_number: "LIC-#{System.unique_integer([:positive])}"
      })

    assert [%{id: id}] = Domain.list_clinicians!()
    assert id == clinician.id
  end

  test "the test host's identities are enforced by the database" do
    license_number = "LIC-#{System.unique_integer([:positive])}"
    Domain.register_clinician!(%{name: "Dr. Ada Moss", license_number: license_number})

    assert {:error, %Ash.Error.Invalid{}} =
             Domain.register_clinician(%{name: "Dr. Ben Ito", license_number: license_number})
  end
end
