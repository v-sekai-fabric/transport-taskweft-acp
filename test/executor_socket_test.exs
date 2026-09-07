# Copyright (c) 2026 K. S. Ernest (iFire) Lee
# SPDX-License-Identifier: MIT

defmodule TaskweftAcp.ExecutorSocketTest do
  use ExUnit.Case, async: false

  alias TaskweftAcp.Executor
  alias TaskweftAcp.Executor.Registry
  alias TaskweftAcp.FakeBao
  alias TaskweftAcp.Transport.WebSocket

  # The hosted door on a random port with the fake bao answering lookup-self, and an
  # executor dialing in from this process's point of view.
  setup do
    bao = FakeBao.start("exec-token", policies: ["default", "taskweft-acp-executor"])
    previous = System.get_env("BAO_ADDR")
    System.put_env("BAO_ADDR", bao.url)
    if Process.whereis(Registry) == nil, do: start_supervised!(Registry)
    ref = :"door_#{System.unique_integer([:positive])}"

    {:ok, _} =
      Plug.Cowboy.http(TaskweftAcpDeploy.Router, [],
        port: 0,
        ip: {127, 0, 0, 1},
        ref: ref,
        dispatch: TaskweftAcpDeploy.Router.dispatch()
      )

    cwd = Path.join(System.tmp_dir!(), "taskweft_acp_exec_#{System.unique_integer([:positive])}")
    File.mkdir_p!(cwd)

    on_exit(fn ->
      _ = Plug.Cowboy.shutdown(ref)
      FakeBao.stop(bao)
      File.rm_rf(cwd)
      if previous, do: System.put_env("BAO_ADDR", previous), else: System.delete_env("BAO_ADDR")
    end)

    %{url: "ws://127.0.0.1:#{:ranch.get_port(ref)}/executor", cwd: cwd}
  end

  test "an executor dials in, registers, and answers requests from its policy", %{
    url: url,
    cwd: cwd
  } do
    File.write!(Path.join(cwd, "note.txt"), "hello")

    {:ok, exec} =
      Executor.start_link(
        url: url,
        token: "exec-token",
        name: "desk-test",
        labels: ["gpu:none"],
        cwd: cwd,
        name_proc: nil,
        bao_policy: %{allow_always: [:run_tests], reject: [:git_commit]}
      )

    entry = await_registered("desk-test")
    assert entry.labels == ["gpu:none"]

    assert {:ok, %{"content" => "hello"}} =
             WebSocket.request(
               entry.pid,
               "fs/read_text_file",
               %{"sessionId" => "s", "path" => Path.join(cwd, "note.txt")},
               5_000
             )

    options =
      for id <- ["allow-once", "allow-always", "reject-once", "reject-always"],
          do: %{"optionId" => id}

    assert {:ok, %{"outcome" => %{"optionId" => "allow-always"}}} =
             WebSocket.request(
               entry.pid,
               "session/request_permission",
               %{
                 "sessionId" => "s",
                 "toolCall" => %{"title" => "run_tests: mix test"},
                 "options" => options
               },
               5_000
             )

    assert {:ok, %{"outcome" => %{"optionId" => "reject-once"}}} =
             WebSocket.request(
               entry.pid,
               "session/request_permission",
               %{
                 "sessionId" => "s",
                 "toolCall" => %{"title" => "git_commit: git commit -m x"},
                 "options" => options
               },
               5_000
             )

    stop_executor(exec)
    assert await_gone("desk-test")
  end

  test "a token without the executor policy is refused and never registers", %{
    url: url,
    cwd: cwd
  } do
    {:ok, exec} =
      Executor.start_link(url: url, token: "wrong", name: "desk-bad", cwd: cwd, name_proc: nil)

    Process.sleep(500)
    assert :error = Registry.lookup("desk-bad")
    stop_executor(exec)
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

  defp await_gone(name, tries \\ 100) do
    case Registry.lookup(name) do
      :error -> true
      {:ok, _} when tries > 0 -> Process.sleep(50) && await_gone(name, tries - 1)
      {:ok, _} -> false
    end
  end

  # The socket is linked to the executor but a normal stop does not reach it.
  defp stop_executor(exec) do
    socket = :sys.get_state(exec).socket
    GenServer.stop(exec)
    if Process.alive?(socket), do: GenServer.stop(socket)
  end
end
