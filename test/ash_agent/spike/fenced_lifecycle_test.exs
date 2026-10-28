# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshAgent.Spike.FencedLifecycleTest do
  @moduledoc false
  use AshAgent.DataCase, async: true

  alias AshAgent.Test.Domain

  test "the fragment's state machine and filtered update work on a plain resource" do
    job = Domain.enqueue_referral!("Send the referral letter to the cardiology clinic")
    assert job.state == :queued
    assert job.lease_epoch == 0

    claimed = Domain.claim_referral!(job)
    assert claimed.state == :running
    assert claimed.lease_epoch == 1

    done = Domain.complete_referral!(claimed, 1, %{result: "sent"})
    assert done.state == :completed
    assert done.result == "sent"
  end

  test "a writer holding an older epoch matches no row" do
    job = "Send the referral letter" |> Domain.enqueue_referral!() |> Domain.claim_referral!()

    assert {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Changes.StaleRecord{}]}} =
             Domain.complete_referral(job, 0, %{result: "late"})

    assert [%{state: :running, result: nil}] =
             Ash.read!(AshAgent.Test.Spike.ReferralJob)
  end

  test "the state machine refuses a transition it does not declare" do
    job = Domain.enqueue_referral!("Send the referral letter")

    assert {:error, %Ash.Error.Invalid{}} = Domain.complete_referral(job, 0)
  end
end
