# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshAgent.Approval.PostureTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias AshAgent.Approval.Posture

  @four_eyes %{"approval" => "four_eyes", "approver_role" => "credentialing_committee"}

  @floored %{
    "approval" => "four_eyes",
    "approver_role" => "credentialing_committee",
    "posture_floor" => true
  }

  @confirm %{"approval" => "confirm"}
  @none %{"approval" => "none"}

  # The three fact regimes: the requester holds the approver role, lacks it
  # while others hold it, and the role has no holders at all.
  @holder %{requester_is_person?: true, requester_holds_role?: true, role_has_holders?: true}
  @lacking %{requester_is_person?: true, requester_holds_role?: false, role_has_holders?: true}
  @empty %{requester_is_person?: true, requester_holds_role?: false, role_has_holders?: false}

  @standard %{candidates: :approver_role, exclude_requester?: true, basis: :four_eyes}
  @with_the_requester %{candidates: :approver_role, exclude_requester?: false, basis: :four_eyes}
  @administrators %{candidates: :administrators, exclude_requester?: false, basis: :small_team}
  @the_requester %{candidates: :requester, exclude_requester?: false, basis: :implementation}

  test "the closed set and the implementation window" do
    assert Posture.postures() == [:standard, :small_team, :implementation]
    assert Posture.max_implementation_days() == 120
    assert Posture.bases() == [:confirm, :four_eyes, :small_team, :implementation]
  end

  describe "effective/3" do
    @now ~U[2026-06-01 12:00:00Z]
    @ended ~U[2026-05-31 12:00:00Z]
    @ahead ~U[2026-07-01 12:00:00Z]

    test ":standard and :small_team never end" do
      assert Posture.effective(:standard, nil, @now) == :standard
      assert Posture.effective(:small_team, nil, @now) == :small_team
    end

    test "an end date that has passed makes the posture :standard" do
      assert Posture.effective(:implementation, @ended, @now) == :standard
      assert Posture.effective(:small_team, @ended, @now) == :standard
    end

    test "an :implementation in force keeps its posture" do
      assert Posture.effective(:implementation, @ahead, @now) == :implementation
    end

    test "an :implementation without an end date is :standard: it cannot run" do
      assert Posture.effective(:implementation, nil, @now) == :standard
    end
  end

  describe "rule/3" do
    test ":none asks nobody, under every posture and every facts" do
      for posture <- Posture.postures(), facts <- [@holder, @lacking, @empty] do
        assert Posture.rule(posture, @none, facts) ==
                 %{candidates: nil, exclude_requester?: false, basis: nil}
      end
    end

    test ":confirm is as declared, under every posture and every facts" do
      for posture <- Posture.postures(), facts <- [@holder, @lacking, @empty] do
        assert Posture.rule(posture, @confirm, facts) ==
                 %{candidates: nil, exclude_requester?: false, basis: :confirm}
      end
    end

    test ":four_eyes under :standard, and at the floor, excludes the requester" do
      for posture <- Posture.postures(), facts <- [@holder, @lacking, @empty] do
        assert Posture.rule(posture, @floored, facts) == @standard
      end

      for facts <- [@holder, @lacking, @empty] do
        assert Posture.rule(:standard, @four_eyes, facts) == @standard
      end
    end

    test ":four_eyes under :small_team" do
      assert Posture.rule(:small_team, @four_eyes, @holder) == @with_the_requester
      assert Posture.rule(:small_team, @four_eyes, @lacking) == @standard
      assert Posture.rule(:small_team, @four_eyes, @empty) == @administrators
    end

    test ":four_eyes under :implementation names the requester, whatever the role" do
      for facts <- [@holder, @lacking, @empty] do
        assert Posture.rule(:implementation, @four_eyes, facts) == @the_requester
      end
    end

    test "an :implementation that has ended reads as :standard" do
      now = DateTime.utc_now()
      posture = Posture.effective(:implementation, DateTime.add(now, -1, :hour), now)
      assert Posture.rule(posture, @four_eyes, @holder) == @standard
    end
  end

  describe "a requester that is not a person" do
    @automation %{
      requester_is_person?: false,
      requester_holds_role?: false,
      role_has_holders?: true
    }
    @automation_alone %{
      requester_is_person?: false,
      requester_holds_role?: false,
      role_has_holders?: false
    }

    test "is never a candidate, under any posture" do
      for posture <- Posture.postures() do
        for facts <- [@automation, @automation_alone] do
          assert Posture.rule(posture, @four_eyes, facts).candidates != :requester
          assert Posture.rule(posture, @floored, facts).candidates != :requester
          assert Posture.rule(posture, @confirm, facts).candidates != :requester
        end
      end
    end

    test "falls back to :standard under :implementation: a person still decides" do
      assert Posture.rule(:implementation, @four_eyes, @automation) == @standard
      assert Posture.rule(:small_team, @four_eyes, @automation) == @standard
    end
  end

  describe "basis/3" do
    test "a self-approval under a :four_eyes pool rests on the small-team posture" do
      assert Posture.basis(@with_the_requester, "p-1", "p-1") == :small_team
      assert Posture.basis(@with_the_requester, "p-2", "p-1") == :four_eyes
    end

    test "the administrators pool rests on :small_team however decided" do
      assert Posture.basis(@administrators, "p-1", "p-1") == :small_team
      assert Posture.basis(@administrators, "p-2", "p-1") == :small_team
    end

    test "an :implementation row: the requester themselves, or the declaration's four eyes" do
      assert Posture.basis(@the_requester, "p-1", "p-1") == :implementation
      assert Posture.basis(@the_requester, "p-2", "p-1") == :four_eyes
      assert Posture.basis(@the_requester, nil, "p-1") == :four_eyes
    end

    test ":confirm rests on the declaration however decided" do
      confirm = %{candidates: nil, exclude_requester?: false, basis: :confirm}

      assert Posture.basis(confirm, "p-1", "p-1") == :confirm
      assert Posture.basis(confirm, "p-2", "p-1") == :confirm
    end
  end
end
