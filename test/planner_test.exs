# Copyright (c) 2026 K. S. Ernest (iFire) Lee
# SPDX-License-Identifier: MIT

defmodule TaskweftAcp.PlannerTest do
  use ExUnit.Case, async: true

  alias TaskweftAcp.{Domain, Planner}

  setup_all do
    {:ok, domain} = Domain.builtin()
    %{domain: domain}
  end

  test "tests_pass decomposes to build then test", %{domain: d} do
    assert {:ok, plan} = Planner.plan(d, [["tests_pass"]])
    assert plan["plan"] == [["run_build"], ["run_tests"]]
    assert is_map(plan["explain"])
  end

  test "committed carries the message through to git_commit", %{domain: d} do
    assert {:ok, plan} = Planner.plan(d, [["committed", "fix the bug"]])

    assert plan["plan"] == [
             ["run_format"],
             ["run_build"],
             ["run_tests"],
             ["git_add"],
             ["git_commit", "fix the bug"]
           ]
  end

  test "an unknown task is refused with a message, never a crash", %{domain: d} do
    assert {:error, message} = Planner.plan(d, [["deploy_to_mars"]])
    assert is_binary(message)
  end

  @alt """
  defmodule Alt do
    use Taskweft.DSL
    @name "alt"
    @variables %{done: %{type: :bool, init: %{job: false}}}
    @actions %{
      a_fast: %{params: [], body: [%{pointer_set: "/done/job", value: true}]},
      a_slow: %{params: [], body: [%{pointer_set: "/done/job", value: true}]}
    }
    @methods %{
      finish: %{
        params: [],
        alternatives: [
          %{name: :fast, subtasks: [["a_fast"]]},
          %{name: :slow, subtasks: [["a_slow"]]}
        ]
      }
    }
    @todo_list []
  end
  """

  test "replan after a failed step takes the other decomposition and keeps the prefix" do
    {:ok, alt} = Domain.load(@alt, "alt.ex")
    {:ok, plan} = Planner.plan(alt, [["finish"]])
    assert plan["plan"] == [["a_fast"]]
    assert {:ok, replanned} = Planner.replan(alt, [["finish"]], plan, 0)
    assert replanned["plan"] == [["a_slow"]]
    assert replanned["completed_steps"] == 0
  end

  test "replan says so when no other decomposition reaches the goal", %{domain: d} do
    todo = [["tests_pass"]]
    {:ok, plan} = Planner.plan(d, todo)
    assert {:error, "no recovery plan from step 1" <> _} = Planner.replan(d, todo, plan, 1)
  end

  test "plan entries mark the prefix completed and the current step in progress" do
    steps = [["a"], ["b"], ["c"]]

    assert Enum.map(Planner.entries(steps, 1, 1), & &1["status"]) == [
             "completed",
             "in_progress",
             "pending"
           ]

    assert Enum.map(Planner.entries(steps, 3, nil), & &1["status"]) == [
             "completed",
             "completed",
             "completed"
           ]
  end
end
