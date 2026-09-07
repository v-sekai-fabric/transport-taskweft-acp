# Copyright (c) 2026 K. S. Ernest (iFire) Lee
# SPDX-License-Identifier: MIT

defmodule TaskweftAcp.Bridge.ClientHandler do
  @moduledoc """
  The ACP client side when there is no editor: files through `File`, terminals through
  `Port`, permissions from a policy map (`%{allow_always: [...], reject: [...]}`; an
  action in neither list is allowed once, and every answer is recorded).
  """

  @behaviour ExMCP.ACP.Client.Handler

  @impl true
  def init(opts) do
    {:ok,
     %{
       policy: Keyword.get(opts, :policy, %{}),
       bridge: Keyword.get(opts, :bridge),
       terminals: %{},
       next: 1
     }}
  end

  alias TaskweftAcp.Executor.Registry
  alias TaskweftAcp.Transport.WebSocket

  # A relaying executor renders the run in its editor, so updates for a bound session
  # go down the same socket its requests come up.
  @impl true
  def handle_session_update(session_id, update, state) do
    case remote(session_id) do
      {:ok, pid} -> WebSocket.update(pid, %{"sessionId" => session_id, "update" => update})
      :local -> :ok
    end

    {:ok, state}
  end

  @impl true
  def handle_permission_request(session_id, tool_call, options, state) do
    case remote(session_id) do
      {:ok, pid} ->
        params = %{"sessionId" => session_id, "toolCall" => tool_call, "options" => options}

        case WebSocket.request(pid, "session/request_permission", params) do
          {:ok, %{"outcome" => outcome}} ->
            {:ok, outcome, state}

          {:ok, other} ->
            {:ok, other, state}

          {:error, reason} ->
            {:ok, %{"outcome" => "cancelled", "reason" => inspect(reason)}, state}
        end

      :local ->
        local_permission(session_id, tool_call, options, state)
    end
  end

  defp local_permission(session_id, tool_call, options, state) do
    action = tool_call["title"] |> to_string() |> String.split(":") |> hd()
    allow_always = Enum.map(Map.get(state.policy, :allow_always, []), &to_string/1)
    reject = Enum.map(Map.get(state.policy, :reject, []), &to_string/1)
    ids = Enum.map(options, & &1["optionId"])

    answer =
      cond do
        action in reject and "reject-once" in ids -> "reject-once"
        action in allow_always and "allow-always" in ids -> "allow-always"
        "allow-once" in ids -> "allow-once"
        true -> hd(ids)
      end

    record(state, session_id, %{"permission" => action, "optionId" => answer})
    {:ok, %{"outcome" => "selected", "optionId" => answer}, state}
  end

  @impl true
  def handle_file_read(session_id, path, opts, state) do
    case remote(session_id) do
      {:ok, pid} ->
        params = Map.merge(%{"sessionId" => session_id, "path" => path}, Map.new(opts || %{}))

        case WebSocket.request(pid, "fs/read_text_file", params) do
          {:ok, %{"content" => content}} -> {:ok, content, state}
          {:ok, other} -> {:error, "unexpected #{inspect(other)}", state}
          {:error, reason} -> {:error, to_string(reason), state}
        end

      :local ->
        local_file_read(path, state)
    end
  end

  defp local_file_read(path, state) do
    case File.read(path) do
      {:ok, content} -> {:ok, content, state}
      {:error, reason} -> {:error, "#{path}: #{:file.format_error(reason)}", state}
    end
  end

  @impl true
  def handle_file_write(session_id, path, content, state) do
    case remote(session_id) do
      {:ok, pid} ->
        params = %{"sessionId" => session_id, "path" => path, "content" => content}

        case WebSocket.request(pid, "fs/write_text_file", params) do
          {:ok, _} -> {:ok, state}
          {:error, reason} -> {:error, to_string(reason), state}
        end

      :local ->
        local_file_write(path, content, state)
    end
  end

  defp local_file_write(path, content, state) do
    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, content) do
      {:ok, state}
    else
      {:error, reason} -> {:error, "#{path}: #{:file.format_error(reason)}", state}
    end
  end

  @impl true
  def handle_terminal_request(method, %{"sessionId" => session_id} = params, id, state)
      when is_binary(session_id) do
    case remote(session_id) do
      {:ok, pid} ->
        timeout = if method == "terminal/wait_for_exit", do: 600_000, else: 30_000

        case WebSocket.request(pid, method, params, timeout) do
          {:ok, result} -> {:ok, result, state}
          {:error, reason} -> {:error, to_string(reason), state}
        end

      :local ->
        local_terminal(method, Map.delete(params, "sessionId"), id, state)
    end
  end

  def handle_terminal_request(method, params, id, state),
    do: local_terminal(method, params, id, state)

  defp local_terminal("terminal/create", params, _id, state) do
    command = params["command"]
    args = params["args"] || []
    cwd = params["cwd"] || File.cwd!()

    case System.find_executable(command) do
      nil ->
        {:error, "no such command: #{command}", state}

      exe ->
        port =
          Port.open({:spawn_executable, exe}, [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            :hide,
            {:args, args},
            {:cd, cwd}
          ])

        id = "term-#{state.next}"
        terminals = Map.put(state.terminals, id, %{port: port, output: [], exit: nil})
        {:ok, %{"terminalId" => id}, %{state | terminals: terminals, next: state.next + 1}}
    end
  end

  defp local_terminal("terminal/wait_for_exit", %{"terminalId" => id}, _rid, state) do
    case Map.fetch(state.terminals, id) do
      :error ->
        {:error, "no terminal #{id}", state}

      {:ok, t} ->
        t = drain(t, :infinity)
        {:ok, %{"exitCode" => t.exit}, put_in(state.terminals[id], t)}
    end
  end

  defp local_terminal("terminal/output", %{"terminalId" => id}, _rid, state) do
    case Map.fetch(state.terminals, id) do
      :error ->
        {:error, "no terminal #{id}", state}

      {:ok, t} ->
        t = drain(t, 0)
        output = t.output |> Enum.reverse() |> IO.iodata_to_binary()
        {:ok, %{"output" => output, "truncated" => false}, put_in(state.terminals[id], t)}
    end
  end

  defp local_terminal("terminal/kill", %{"terminalId" => id}, _rid, state) do
    case Map.fetch(state.terminals, id) do
      :error ->
        {:error, "no terminal #{id}", state}

      {:ok, %{port: port}} ->
        _ = if t_alive?(port), do: Port.close(port)
        {:ok, %{}, state}
    end
  end

  defp local_terminal("terminal/release", %{"terminalId" => id}, _rid, state) do
    {:ok, %{}, %{state | terminals: Map.delete(state.terminals, id)}}
  end

  defp local_terminal(method, _params, _rid, state), do: {:error, "unsupported #{method}", state}

  defp remote(session_id) do
    case Registry.executor_for(session_id) do
      {:ok, pid} when is_pid(pid) -> {:ok, pid}
      _ -> :local
    end
  end

  @impl true
  def terminate(_reason, _state), do: :ok

  # Collect what the port has produced; with :infinity, wait for the exit status.
  defp drain(%{exit: exit} = t, _timeout) when is_integer(exit), do: t

  defp drain(%{port: port} = t, timeout) do
    receive do
      {^port, {:data, chunk}} -> drain(%{t | output: [chunk | t.output]}, timeout)
      {^port, {:exit_status, code}} -> %{t | exit: code}
    after
      timeout -> t
    end
  end

  defp t_alive?(port), do: Port.info(port) != nil

  defp record(%{bridge: nil}, _sid, _line), do: :ok
  defp record(%{bridge: bridge}, sid, line), do: GenServer.cast(bridge, {:record, sid, line})
end
