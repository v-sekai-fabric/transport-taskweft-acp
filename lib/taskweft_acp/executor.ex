# Copyright (c) 2026 K. S. Ernest (iFire) Lee
# SPDX-License-Identifier: MIT

defmodule TaskweftAcp.Executor do
  @moduledoc """
  An executor side: a desk or a build box that dials in to the hosted door and answers
  the client-side requests of the sessions bound to it. Files and terminals run here;
  permissions are decided here from the OpenBao policy with the local override; the
  hosted side records what was decided and never decides it.

  In relay mode (`editor: true`) the same process is also an ACP agent toward an editor
  over stdio: prompts go up to the hosted door, and every request the door makes for a
  relayed session is put to the human in the editor instead of to the policy.
  """

  use GenServer
  require Logger

  alias ExMCP.ACP.Agent, as: Acp
  alias TaskweftAcp.Bridge.ClientHandler
  alias TaskweftAcp.Executor.{Policy, Socket}

  defstruct [:cwd, :policy, :handler_state, :socket, :name, :agent, editor: false]

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name_proc, __MODULE__))

  @impl true
  def init(opts) do
    cwd = Keyword.get(opts, :cwd, File.cwd!())
    policy = Policy.load(cwd, bao: Keyword.get(opts, :bao_policy, %{}))
    {:ok, handler_state} = ClientHandler.init(policy: %{}, bridge: nil)
    editor = Keyword.get(opts, :editor, false)
    me = self()

    {:ok, socket} =
      Socket.start_link(
        url: Keyword.fetch!(opts, :url),
        token: Keyword.fetch!(opts, :token),
        name: Keyword.fetch!(opts, :name),
        labels: Keyword.get(opts, :labels, []),
        handler: fn method, params -> GenServer.call(me, {:serve, method, params}, :infinity) end,
        updates: if(editor, do: fn params -> send(me, {:update, params}) end)
      )

    state = %__MODULE__{
      cwd: cwd,
      policy: policy,
      handler_state: handler_state,
      socket: socket,
      name: Keyword.fetch!(opts, :name),
      editor: editor
    }

    if editor,
      do: {:ok, state, {:continue, {:editor, Keyword.get(opts, :agent_opts, [])}}},
      else: {:ok, state}
  end

  @doc "The socket this executor dials with, so the editor's agent can send through it."
  @spec socket(GenServer.server()) :: pid()
  def socket(executor \\ __MODULE__), do: GenServer.call(executor, :socket)

  @impl true
  def handle_continue({:editor, agent_opts}, s) do
    opts =
      Keyword.merge(
        [
          handler: TaskweftAcp.Executor.Relay,
          handler_opts: [socket: s.socket],
          agent_info: TaskweftAcp.agent_info(),
          transport: :stdio
        ],
        agent_opts
      )

    {:ok, agent} = ExMCP.ACP.start_agent(opts)
    {:noreply, %{s | agent: agent}}
  end

  @impl true
  def handle_info({:update, params}, %{agent: agent} = s) when agent != nil do
    _ =
      ExMCP.ACP.Agent.session_update(agent, params["sessionId"], params["update"] || params)

    {:noreply, s}
  end

  def handle_info(_other, s), do: {:noreply, s}

  @impl true
  def handle_call(:socket, _from, s), do: {:reply, s.socket, s}

  # Relay mode: the human in the editor answers, so the policy is not consulted at all.
  def handle_call({:serve, method, params}, _from, %{editor: true, agent: agent} = s)
      when agent != nil do
    {:reply, ask_editor(agent, method, params), s}
  end

  def handle_call({:serve, "session/request_permission", params}, _from, s) do
    action = params["toolCall"]["title"] |> to_string() |> String.split(":") |> hd()
    answer = Policy.decide(s.policy, action)
    ids = Enum.map(params["options"] || [], & &1["optionId"])
    answer = if answer in ids, do: answer, else: "reject-once"
    Logger.info("executor #{s.name}: #{action} -> #{answer}")
    {:reply, {:ok, %{"outcome" => %{"outcome" => "selected", "optionId" => answer}}}, s}
  end

  def handle_call({:serve, "fs/read_text_file", params}, _from, s) do
    case ClientHandler.handle_file_read(
           params["sessionId"],
           params["path"],
           params,
           s.handler_state
         ) do
      {:ok, content, hs} -> {:reply, {:ok, %{"content" => content}}, %{s | handler_state: hs}}
      {:error, reason, hs} -> {:reply, {:error, reason}, %{s | handler_state: hs}}
    end
  end

  def handle_call({:serve, "fs/write_text_file", params}, _from, s) do
    case ClientHandler.handle_file_write(
           params["sessionId"],
           params["path"],
           params["content"],
           s.handler_state
         ) do
      {:ok, hs} -> {:reply, {:ok, %{}}, %{s | handler_state: hs}}
      {:error, reason, hs} -> {:reply, {:error, reason}, %{s | handler_state: hs}}
    end
  end

  def handle_call({:serve, "terminal/" <> _ = method, params}, _from, s) do
    params = Map.put_new(params, "cwd", s.cwd)

    case ClientHandler.handle_terminal_request(method, params, params["id"], s.handler_state) do
      {:ok, result, hs} -> {:reply, {:ok, result}, %{s | handler_state: hs}}
      {:error, reason, hs} -> {:reply, {:error, reason}, %{s | handler_state: hs}}
    end
  end

  def handle_call({:serve, method, _params}, _from, s),
    do: {:reply, {:error, "unsupported #{method}"}, s}

  defp ask_editor(agent, "session/request_permission", p) do
    case Acp.request_permission(agent, p["sessionId"], p["toolCall"], p["options"] || []) do
      {:ok, outcome} -> {:ok, %{"outcome" => outcome}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp ask_editor(agent, "fs/read_text_file", p) do
    case Acp.read_text_file(agent, p["sessionId"], p["path"]) do
      {:ok, %{"content" => content}} -> {:ok, %{"content" => content}}
      {:ok, nil} -> {:error, "empty response"}
      {:ok, other} -> {:ok, %{"content" => other}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp ask_editor(agent, "fs/write_text_file", p) do
    case Acp.write_text_file(agent, p["sessionId"], p["path"], p["content"]) do
      {:ok, _} -> {:ok, %{}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp ask_editor(agent, "terminal/create", p) do
    Acp.terminal_create(agent, p["sessionId"], Map.drop(p, ["sessionId"]))
  end

  defp ask_editor(agent, "terminal/output", p),
    do: Acp.terminal_output(agent, p["sessionId"], p["terminalId"])

  defp ask_editor(agent, "terminal/wait_for_exit", p),
    do: Acp.terminal_wait_for_exit(agent, p["sessionId"], p["terminalId"])

  defp ask_editor(agent, "terminal/kill", p),
    do: Acp.terminal_kill(agent, p["sessionId"], p["terminalId"])

  defp ask_editor(agent, "terminal/release", p),
    do: Acp.terminal_release(agent, p["sessionId"], p["terminalId"])

  defp ask_editor(_agent, method, _p), do: {:error, "unsupported #{method}"}
end
