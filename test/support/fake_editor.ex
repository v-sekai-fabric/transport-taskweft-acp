# Copyright (c) 2026 K. S. Ernest (iFire) Lee
# SPDX-License-Identifier: MIT

defmodule TaskweftAcp.FakeEditor do
  @moduledoc """
  A scripted ACP client handler standing in for the editor: answers permission requests
  from a script, keeps an in-memory file system, runs "terminals" from a table of
  command → {exit, output}, and forwards every session update to the test process.
  """

  @behaviour ExMCP.ACP.Client.Handler

  @impl true
  def init(opts) do
    {:ok,
     %{
       test: Keyword.fetch!(opts, :test),
       permissions: Keyword.get(opts, :permissions, ["allow-once"]),
       files: Keyword.get(opts, :files, %{}),
       commands: Keyword.get(opts, :commands, %{}),
       terminals: %{},
       next_terminal: 1
     }}
  end

  @impl true
  def handle_session_update(session_id, update, state) do
    send(state.test, {:update, session_id, update})
    {:ok, state}
  end

  @impl true
  def handle_permission_request(session_id, tool_call, options, state) do
    {answer, rest} =
      case state.permissions do
        [only] -> {only, [only]}
        [head | tail] -> {head, tail}
      end

    send(state.test, {:permission, session_id, tool_call, answer})
    ids = Enum.map(options, & &1["optionId"])

    if answer in ids do
      {:ok, %{"outcome" => "selected", "optionId" => answer}, %{state | permissions: rest}}
    else
      {:ok, %{"outcome" => "cancelled"}, %{state | permissions: rest}}
    end
  end

  @impl true
  def handle_file_read(_session_id, path, _opts, state) do
    case Map.fetch(state.files, path) do
      {:ok, content} -> {:ok, content, state}
      :error -> {:error, "no such file #{path}", state}
    end
  end

  @impl true
  def handle_file_write(_session_id, path, content, state) do
    {:ok, %{state | files: Map.put(state.files, path, content)}}
  end

  @impl true
  def handle_terminal_request("terminal/create", params, _id, state) do
    key = Enum.join([params["command"] | params["args"] || []], " ")
    {exit_code, output} = Map.get(state.commands, key, {0, "ran #{key}"})
    id = "term-#{state.next_terminal}"
    send(state.test, {:terminal, key})

    {:ok, %{"terminalId" => id},
     %{
       state
       | terminals: Map.put(state.terminals, id, {exit_code, output}),
         next_terminal: state.next_terminal + 1
     }}
  end

  def handle_terminal_request("terminal/output", %{"terminalId" => id}, _rid, state) do
    {_exit, output} = Map.fetch!(state.terminals, id)
    {:ok, %{"output" => output, "truncated" => false}, state}
  end

  def handle_terminal_request("terminal/wait_for_exit", %{"terminalId" => id}, _rid, state) do
    {exit_code, _} = Map.fetch!(state.terminals, id)
    {:ok, %{"exitCode" => exit_code}, state}
  end

  def handle_terminal_request(method, %{"terminalId" => _id}, _rid, state)
      when method in ["terminal/release", "terminal/kill"] do
    {:ok, %{}, state}
  end

  @impl true
  def terminate(_reason, _state), do: :ok
end
