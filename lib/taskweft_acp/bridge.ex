# Copyright (c) 2026 K. S. Ernest (iFire) Lee
# SPDX-License-Identifier: MIT

defmodule TaskweftAcp.Bridge do
  @moduledoc """
  The Claude Code door: an ACP client of the same agent, in-VM over ex_mcp's memory
  transport, exposed as MCP tools. Claude Code has no editor, so the bridge's client
  handler answers file, terminal and permission requests itself (the `fly` executor
  case) and every update is kept as a transcript the tools hand back.
  """

  use GenServer

  alias ExMCP.ACP.Agent.Transport.Memory
  alias ExMCP.ACP.Client
  alias TaskweftAcp.Bridge.ClientHandler

  defstruct client: nil, agent: nil, transcript: %{}

  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @spec new_session(GenServer.server(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def new_session(bridge \\ __MODULE__, cwd, opts \\ []),
    do: GenServer.call(bridge, {:new_session, cwd, opts}, 60_000)

  @spec load_session(GenServer.server(), String.t(), String.t()) :: :ok | {:error, term()}
  def load_session(bridge \\ __MODULE__, id, cwd),
    do: GenServer.call(bridge, {:load_session, id, cwd}, 60_000)

  @spec prompt(GenServer.server(), String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def prompt(bridge \\ __MODULE__, id, text),
    do: GenServer.call(bridge, {:prompt, id, text}, :infinity)

  @spec sessions(GenServer.server()) :: {:ok, [map()]} | {:error, term()}
  def sessions(bridge \\ __MODULE__), do: GenServer.call(bridge, :sessions, 30_000)

  @spec cancel(GenServer.server(), String.t()) :: :ok
  def cancel(bridge \\ __MODULE__, id), do: GenServer.call(bridge, {:cancel, id})

  @spec close(GenServer.server(), String.t()) :: :ok | {:error, term()}
  def close(bridge \\ __MODULE__, id), do: GenServer.call(bridge, {:close, id}, 30_000)

  @impl true
  def init(opts) do
    {:ok, peer} = Memory.new_pair()

    {:ok, agent} =
      ExMCP.ACP.Agent.start_link(
        handler: TaskweftAcp.Agent,
        handler_opts: Keyword.get(opts, :handler_opts, []),
        agent_info: TaskweftAcp.agent_info(),
        transport: {:memory, peer}
      )

    {:ok, client} =
      Client.start_link(
        transport_mod: Memory,
        peer: peer,
        role: :client,
        handler: ClientHandler,
        handler_opts: [policy: Keyword.get(opts, :policy, %{}), bridge: self()],
        event_listener: self(),
        client_info: %{"name" => "taskweft-acp-bridge", "version" => TaskweftAcp.version()},
        capabilities: %{
          "fs" => %{"readTextFile" => true, "writeTextFile" => true},
          "terminal" => true
        }
      )

    {:ok, %__MODULE__{client: client, agent: agent}}
  end

  @impl true
  def handle_call({:new_session, cwd, opts}, _from, s) do
    executor = Keyword.get(opts, :executor)

    with {:ok, _} <- executor_connected(executor),
         {:ok, %{"sessionId" => id}} <- Client.new_session(s.client, cwd) do
      if executor, do: :ok = TaskweftAcp.Executor.Registry.bind(id, executor)
      {:reply, {:ok, id}, %{s | transcript: Map.put(s.transcript, id, [])}}
    else
      {:error, _} = e -> {:reply, e, s}
    end
  end

  def handle_call({:load_session, id, cwd}, _from, s) do
    s = %{s | transcript: Map.put(s.transcript, id, [])}

    case Client.load_session(s.client, id, cwd) do
      {:ok, _} -> {:reply, :ok, s}
      {:error, _} = e -> {:reply, e, s}
    end
  end

  def handle_call({:prompt, id, text}, from, s) do
    s = %{s | transcript: Map.put(s.transcript, id, [])}
    client = s.client
    bridge = self()

    # The prompt blocks for the whole run; the updates arrive here meanwhile.
    {:ok, _} =
      Task.start(fn ->
        result = Client.prompt(client, id, text)
        GenServer.cast(bridge, {:prompt_done, id, from, result})
      end)

    {:noreply, s}
  end

  def handle_call(:sessions, _from, s) do
    case Client.list_sessions(s.client) do
      {:ok, %{"sessions" => sessions}} -> {:reply, {:ok, sessions}, s}
      {:ok, other} -> {:reply, {:error, {:unexpected, other}}, s}
      {:error, _} = e -> {:reply, e, s}
    end
  end

  def handle_call({:cancel, id}, _from, s) do
    :ok = Client.cancel(s.client, id)
    {:reply, :ok, s}
  end

  def handle_call({:close, id}, _from, s) do
    case Client.close_session(s.client, id) do
      {:ok, _} -> {:reply, :ok, %{s | transcript: Map.delete(s.transcript, id)}}
      {:error, _} = e -> {:reply, e, s}
    end
  end

  # A session may be bound only to an executor that is connected right now; nothing
  # runs on this machine by default.
  defp executor_connected(nil), do: {:ok, :local}

  defp executor_connected(name) do
    case TaskweftAcp.Executor.Registry.lookup(name) do
      {:ok, entry} -> {:ok, entry}
      :error -> {:error, {:executor_not_connected, name}}
    end
  end

  @impl true
  def handle_cast({:prompt_done, id, from, result}, s) do
    lines = s.transcript |> Map.get(id, []) |> Enum.reverse()

    reply =
      case result do
        {:ok, %{"stopReason" => reason}} -> {:ok, %{stop_reason: reason, transcript: lines}}
        {:ok, other} -> {:error, {:unexpected, other}}
        {:error, reason} -> {:error, reason}
      end

    GenServer.reply(from, reply)
    {:noreply, s}
  end

  def handle_cast({:record, id, line}, s) do
    {:noreply, %{s | transcript: Map.update(s.transcript, id, [line], &[line | &1])}}
  end

  @impl true
  def handle_info({:acp_session_update, id, update}, s) do
    {:noreply, %{s | transcript: Map.update(s.transcript, id, [update], &[update | &1])}}
  end

  def handle_info(_other, s), do: {:noreply, s}
end
