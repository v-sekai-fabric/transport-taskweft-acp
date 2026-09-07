# Copyright (c) 2026 K. S. Ernest (iFire) Lee
# SPDX-License-Identifier: MIT

defmodule TaskweftAcp.StoreBaoTest do
  use ExUnit.Case, async: false

  alias TaskweftAcp.FakeBao
  alias TaskweftAcp.Session
  alias TaskweftAcp.Session.Store

  setup do
    bao = FakeBao.start("token-1")
    on_exit(fn -> FakeBao.stop(bao) end)
    %{bao: bao, opts: [bao_addr: bao.url, bao_token: "token-1"]}
  end

  test "the fallback adapter round-trips through the mount", %{opts: opts} do
    {:ok, store} = Store.start_link(name: nil, adapter: Store.Bao, adapter_opts: opts)
    assert :ok = Store.create_session(store, "acp_b1", %{"cwd" => "C:/w"})

    assert {:ok, 1} =
             Store.append(
               store,
               "acp_b1",
               Session.event(:client_to_agent, "session/new", %{"cwd" => "C:/w"})
             )

    assert {:ok, 2} =
             Store.append(
               store,
               "acp_b1",
               Session.event(:agent_to_client, "acp/plan", %{
                 "plan" => %{"plan" => [["run_tests"]]},
                 "completed_steps" => 0
               })
             )

    assert {:ok, [only]} = Store.events(store, "acp_b1", 1)
    assert only["method"] == "acp/plan"
    assert only["payload"]["plan"]["plan"] == [["run_tests"]]
    assert {:ok, [%{"id" => "acp_b1", "cwd" => "C:/w"}]} = Store.sessions(store, "C:/w")
    assert %{adapter: Store.Bao, mode: :primary} = Store.status(store)
  end

  test "a wrong token is a named error, not an unreachable store", %{bao: bao} do
    Process.flag(:trap_exit, true)

    assert {:error, {:store_unreachable, {:sql, message}}} =
             Store.start_link(
               name: nil,
               adapter: Store.Bao,
               adapter_opts: [bao_addr: bao.url, bao_token: "wrong"]
             )

    assert message =~ "HTTP 403"
  end

  test "an unreachable primary switches to bao mid-session, and the switch is logged first",
       %{bao: bao, opts: opts} do
    {:ok, store} =
      Store.start_link(
        name: nil,
        adapter: Store.Memory,
        fallback: Store.Bao,
        adapter_opts: [fail: {:append, {:unreachable, :cluster_gone}}] ++ opts
      )

    assert :ok = Store.create_session(store, "acp_b2", %{"cwd" => "C:/w"})

    assert {:ok, 2} =
             Store.append(store, "acp_b2", Session.event(:client_to_agent, "session/new", %{}))

    assert %{adapter: Store.Bao, mode: :fallback} = Store.status(store)

    writes =
      for {:exec, "acp_acp_b2", "acp_event_append", p} <- FakeBao.calls(bao.db),
          do: p["method"]

    assert writes == ["acp/fallback", "session/new"]
    assert {:ok, [first | _]} = Store.events(store, "acp_b2", 0)
    assert first["payload"]["active"] == "bao"
    assert first["payload"]["reason"] =~ "cluster_gone"
  end

  test "a plain error does not switch to bao", %{bao: bao, opts: opts} do
    {:ok, store} =
      Store.start_link(
        name: nil,
        adapter: Store.Memory,
        fallback: Store.Bao,
        adapter_opts: [fail: {:append, {:sql, "constraint"}}] ++ opts
      )

    :ok = Store.create_session(store, "acp_b3", %{"cwd" => "C:/w"})

    assert {:error, {:sql, "constraint"}} =
             Store.append(store, "acp_b3", Session.event(:client_to_agent, "session/new", %{}))

    assert %{adapter: Store.Memory, mode: :primary} = Store.status(store)
    assert FakeBao.calls(bao.db) == []
  end
end
