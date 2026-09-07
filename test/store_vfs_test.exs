# Copyright (c) 2026 K. S. Ernest (iFire) Lee
# SPDX-License-Identifier: MIT

defmodule TaskweftAcp.StoreVfsTest do
  use ExUnit.Case, async: false

  alias TaskweftAcp.Session
  alias TaskweftAcp.Session.Store

  # Plain mode through the real helper. A missing helper is a failure, not a skip: CI
  # builds it with `make` before the tests run.
  setup do
    dir = Path.join(System.tmp_dir!(), "taskweft_acp_store_#{System.unique_integer([:positive])}")

    {:ok, store} =
      Store.start_link(name: nil, adapter: Store.Vfs, adapter_opts: [mode: :plain, dir: dir])

    on_exit(fn -> File.rm_rf(dir) end)
    %{store: store, dir: dir}
  end

  test "a session's events round-trip with ordinals allocated in the transaction", %{store: store} do
    assert :ok = Store.create_session(store, "acp_t1", %{"cwd" => "C:/w"})
    e1 = Session.event(:client_to_agent, "session/new", %{"cwd" => "C:/w"})

    e2 =
      Session.event(:agent_to_client, "acp/plan", %{
        "plan" => %{"plan" => [["run_tests"]]},
        "completed_steps" => 0
      })

    assert {:ok, 1} = Store.append(store, "acp_t1", e1)
    assert {:ok, 2} = Store.append(store, "acp_t1", e2)
    assert {:ok, events} = Store.events(store, "acp_t1", 0)
    assert Enum.map(events, & &1["ordinal"]) == [1, 2]
    assert Enum.at(events, 1)["payload"]["plan"]["plan"] == [["run_tests"]]
    assert {:ok, [only]} = Store.events(store, "acp_t1", 1)
    assert only["method"] == "acp/plan"
  end

  test "the registry lists sessions by cwd, newest first", %{store: store} do
    :ok =
      Store.create_session(store, "acp_a", %{
        "cwd" => "C:/one",
        "created_at" => "2026-09-07T01:00:00Z"
      })

    :ok =
      Store.create_session(store, "acp_b", %{
        "cwd" => "C:/one",
        "created_at" => "2026-09-07T02:00:00Z"
      })

    :ok = Store.create_session(store, "acp_c", %{"cwd" => "C:/two"})
    assert {:ok, [%{"id" => "acp_b"}, %{"id" => "acp_a"}]} = Store.sessions(store, "C:/one")
    assert {:ok, all} = Store.sessions(store, :all)
    assert length(all) == 3
  end

  test "the store survives a restart: a second store reads what the first wrote", %{
    store: store,
    dir: dir
  } do
    :ok = Store.create_session(store, "acp_p", %{"cwd" => "C:/w"})
    {:ok, 1} = Store.append(store, "acp_p", Session.event(:client_to_agent, "session/new", %{}))
    GenServer.stop(store)

    {:ok, again} =
      Store.start_link(name: nil, adapter: Store.Vfs, adapter_opts: [mode: :plain, dir: dir])

    assert {:ok, [%{"method" => "session/new"}]} = Store.events(again, "acp_p", 0)
    assert %{adapter: Store.Vfs, mode: :primary} = Store.status(again)
  end

  test "a SQL error is named and does not switch adapters", %{store: store} do
    assert {:error, {:sql, message}} = Store.events(store, "../not-a-name", 0)
    assert is_binary(message)
    assert %{mode: :primary} = Store.status(store)
  end

  test "an unreachable primary fails the boot when there is no fallback" do
    Process.flag(:trap_exit, true)

    assert {:error, {:store_unreachable, {:unreachable, {:no_helper, _}}}} =
             Store.start_link(
               name: nil,
               adapter: Store.Vfs,
               adapter_opts: [mode: :plain, dir: System.tmp_dir!(), helper: "does-not-exist"]
             )
  end
end
