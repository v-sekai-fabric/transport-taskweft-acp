# Copyright (c) 2026 K. S. Ernest (iFire) Lee
# SPDX-License-Identifier: MIT

defmodule TaskweftAcp.Executor do
  @moduledoc """
  An executor side: a desk or a build box that dials in to the hosted door and answers
  the client-side requests of the sessions bound to it. Files and terminals run here;
  permissions are decided here from the OpenBao policy with the local override; the
  hosted side records what was decided and never decides it.
  """

  use GenServer
  require Logger

  alias TaskweftAcp.Bridge.ClientHandler
  alias TaskweftAcp.Executor.{Policy, Socket}

  defstruct [:cwd, :policy, :handler_state, :socket, :name]

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name_proc, __MODULE__))

  @impl true
  def init(opts) do
    cwd = Keyword.get(opts, :cwd, File.cwd!())
    policy = Policy.load(cwd, bao: Keyword.get(opts, :bao_policy, %{}))
    {:ok, handler_state} = ClientHandler.init(policy: %{}, bridge: nil)
    me = self()

    {:ok, socket} =
      Socket.start_link(
        url: Keyword.fetch!(opts, :url),
        token: Keyword.fetch!(opts, :token),
        name: Keyword.fetch!(opts, :name),
        labels: Keyword.get(opts, :labels, []),
        handler: fn method, params -> GenServer.call(me, {:serve, method, params}, :infinity) end
      )

    {:ok,
     %__MODULE__{
       cwd: cwd,
       policy: policy,
       handler_state: handler_state,
       socket: socket,
       name: Keyword.fetch!(opts, :name)
     }}
  end

  @impl true
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
end
