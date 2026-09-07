# Copyright (c) 2026 K. S. Ernest (iFire) Lee
# SPDX-License-Identifier: MIT

defmodule TaskweftAcp.RelayTest do
  use ExUnit.Case, async: false

  alias ExMCP.ACP.Agent.Transport.Memory
  alias ExMCP.ACP.Client
  alias TaskweftAcp.Executor
  alias TaskweftAcp.Executor.Registry
  alias TaskweftAcp.FakeBao
  alias TaskweftAcp.FakeEditor

  @moduledoc """
  Relay editor mode end to end: a fake editor drives the relay's stdio agent, the relay
  drives a hosted door over a real WebSocket, and the door's permission request comes
  back to the editor. The control is the same run without `--editor`, where the policy
  answers and the editor is never asked.
  """

  setup do
    bao = FakeBao.start("exec-token", policies: ["default", "taskweft-acp-executor"])
    previous = System.get_env("BAO_ADDR")
    System.put_env("BAO_ADDR", bao.url)
    if Process.whereis(Registry) == nil, do: start_supervised!(Registry)

    {:ok, store} =
      TaskweftAcp.Session.Store.start_link(name: nil, adapter: TaskweftAcp.Session.Store.Memory)

    {:ok, _bridge} = TaskweftAcp.Bridge.start_link(handler_opts: [store: store])
    ref = :"relay_door_#{System.unique_integer([:positive])}"

    {:ok, _} =
      Plug.Cowboy.http(TaskweftAcpDeploy.Router, [],
        port: 0,
        ip: {127, 0, 0, 1},
        ref: ref,
        dispatch: TaskweftAcpDeploy.Router.dispatch()
      )

    cwd = Path.join(System.tmp_dir!(), "taskweft_acp_relay_#{System.unique_integer([:positive])}")
    File.mkdir_p!(cwd)

    on_exit(fn ->
      _ = Plug.Cowboy.shutdown(ref)
      FakeBao.stop(bao)
      File.rm_rf(cwd)
      if previous, do: System.put_env("BAO_ADDR", previous), else: System.delete_env("BAO_ADDR")
    end)

    %{url: "ws://127.0.0.1:#{:ranch.get_port(ref)}/executor", cwd: cwd}
  end

  test "the editor answers the permission, and the plan reaches it as an update", %{
    url: url,
    cwd: cwd
  } do
    {editor, exec} = start_relay(url, cwd, permissions: ["allow-once"])
    {:ok, %{"sessionId" => sid}} = Client.new_session(editor, cwd)
    assert is_binary(sid)

    {:ok, _} = Client.prompt(editor, sid, "/task tests_pass")
    assert_receive {:update, ^sid, %{"sessionUpdate" => "agent_message_chunk"}}, 10_000

    {:ok, %{"stopReason" => stop}} = Client.prompt(editor, sid, "/run")
    assert stop in ["end_turn", "refusal", "cancelled"]
    assert_receive {:permission, ^sid, tool_call, "allow-once"}, 10_000
    assert tool_call["title"] =~ "run_build"
    assert_receive {:terminal, "mix compile --warnings-as-errors"}, 10_000

    stop_relay(editor, exec)
  end

  test "without the editor flag no editor side exists", %{url: url, cwd: cwd} do
    {editor, exec} =
      start_relay(url, cwd, editor: false, bao_policy: %{allow_always: [], reject: []})

    assert editor == :no_editor_side
    refute_receive {:permission, _, _, _}, 200
    stop_relay(editor, exec)
  end

  defp start_relay(url, cwd, opts) do
    editor? = Keyword.get(opts, :editor, true)
    Process.flag(:trap_exit, true)
    {:ok, peer} = Memory.new_pair()

    {:ok, exec} =
      Executor.start_link(
        url: url,
        token: "exec-token",
        name: "relay-test",
        cwd: cwd,
        name_proc: nil,
        editor: editor?,
        bao_policy: Keyword.get(opts, :bao_policy, %{}),
        agent_opts: [transport: {:memory, peer}]
      )

    await_registered("relay-test")

    editor =
      case Client.start_link(
             transport_mod: Memory,
             peer: peer,
             role: :client,
             handler: FakeEditor,
             handler_opts: [
               test: self(),
               permissions: Keyword.get(opts, :permissions, ["allow-once"]),
               commands: %{}
             ],
             event_listener: self(),
             capabilities: %{
               "fs" => %{"readTextFile" => true, "writeTextFile" => true},
               "terminal" => true
             }
           ) do
        {:ok, pid} -> pid
        {:error, :init_timeout} -> :no_editor_side
      end

    {editor, exec}
  end

  defp stop_relay(editor, exec) do
    socket = :sys.get_state(exec).socket
    if is_pid(editor) and Process.alive?(editor), do: GenServer.stop(editor)
    GenServer.stop(exec)
    if Process.alive?(socket), do: GenServer.stop(socket)
  end

  defp await_registered(name, tries \\ 100) do
    case Registry.lookup(name) do
      {:ok, entry} ->
        entry

      :error when tries > 0 ->
        Process.sleep(50)
        await_registered(name, tries - 1)

      :error ->
        flunk("executor #{name} never registered")
    end
  end
end
