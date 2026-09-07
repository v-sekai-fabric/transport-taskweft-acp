# Copyright (c) 2026 K. S. Ernest (iFire) Lee
# SPDX-License-Identifier: MIT

defmodule TaskweftAcp.BridgeTest do
  use ExUnit.Case, async: false

  alias TaskweftAcp.Bridge
  alias TaskweftAcp.Session.Store

  setup do
    {:ok, store} = Store.start_link(name: nil, adapter: Store.Memory)

    {:ok, bridge} =
      Bridge.start_link(name: nil, handler_opts: [store: store], policy: %{reject: [:git_commit]})

    on_exit(fn ->
      try do
        GenServer.stop(bridge)
      catch
        :exit, _ -> :ok
      end
    end)

    %{bridge: bridge}
  end

  test "a session opens, plans and lists through the bridge", %{bridge: bridge} do
    assert {:ok, id} = Bridge.new_session(bridge, File.cwd!())

    assert {:ok, %{stop_reason: "end_turn", transcript: lines}} =
             Bridge.prompt(bridge, id, "/plan tests pass")

    rendered = TaskweftAcp.Bridge.McpServer.render("end_turn", lines)
    assert rendered =~ "[pending] run_build"
    assert rendered =~ "[pending] run_tests"
    assert {:ok, sessions} = Bridge.sessions(bridge)
    assert Enum.any?(sessions, &(&1["sessionId"] == id))
  end

  test "the in-BEAM client runs a real command and records the permission", %{bridge: bridge} do
    tmp =
      Path.join(System.tmp_dir!(), "taskweft_acp_bridge_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp)
    File.mkdir_p!(Path.join(tmp, ".taskweft-acp"))

    exe = if match?({:win32, _}, :os.type()), do: "cmd", else: "sh"
    flag = if exe == "cmd", do: "/c", else: "-c"

    File.write!(
      Path.join(tmp, ".taskweft-acp/config.exs"),
      "%{exec: %{run_build: %{command: #{inspect(exe)}, args: [#{inspect(flag)}, \"echo built\"]}, run_tests: %{command: #{inspect(exe)}, args: [#{inspect(flag)}, \"echo tested\"]}}}\n"
    )

    assert {:ok, id} = Bridge.new_session(bridge, tmp)

    assert {:ok, %{stop_reason: "end_turn", transcript: lines}} =
             Bridge.prompt(bridge, id, "/run tests pass")

    rendered = TaskweftAcp.Bridge.McpServer.render("end_turn", lines)
    assert rendered =~ "permission run_build: allow-once"
    assert rendered =~ "step step-1-0: completed"
    assert rendered =~ "tested"
    File.rm_rf!(tmp)
  end

  test "a rejected action from the policy ends the run with no recovery", %{bridge: bridge} do
    tmp =
      Path.join(System.tmp_dir!(), "taskweft_acp_policy_#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(tmp, ".taskweft-acp"))
    exe = if match?({:win32, _}, :os.type()), do: "cmd", else: "sh"
    flag = if exe == "cmd", do: "/c", else: "-c"

    echo =
      Enum.map_join(
        ~w(run_format run_build run_tests git_add git_commit),
        ", ",
        &"#{&1}: %{command: #{inspect(exe)}, args: [#{inspect(flag)}, \"echo #{&1}\"]}"
      )

    File.write!(Path.join(tmp, ".taskweft-acp/config.exs"), "%{exec: %{#{echo}}}
")
    assert {:ok, id} = Bridge.new_session(bridge, tmp)

    assert {:ok, %{stop_reason: "end_turn", transcript: lines}} =
             Bridge.prompt(bridge, id, "/run commit hello")

    rendered = TaskweftAcp.Bridge.McpServer.render("end_turn", lines)
    assert rendered =~ "permission run_format: allow-once"
    assert rendered =~ "permission git_commit: reject-once"
    assert rendered =~ "no recovery plan"
    File.rm_rf!(tmp)
  end
end
