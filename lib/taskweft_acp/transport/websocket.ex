# Copyright (c) 2026 K. S. Ernest (iFire) Lee
# SPDX-License-Identifier: MIT

defmodule TaskweftAcp.Transport.WebSocket do
  @moduledoc """
  The `/executor` endpoint on the hosted door. An executor side dials in with an OpenBao
  token, a name and labels, and from then on answers the ACP client-side requests for
  the sessions bound to it: file reads and writes, terminals, permissions. The hosted
  agent never runs a step itself unless the session is bound to the `fly` executor.

  Frames are JSON lines: server → executor `{"id", "method", "params"}`, executor →
  server `{"id", "result"}` or `{"id", "error"}`; the executor may also send
  `{"event": "ping"}`.

  Relay editor mode reverses one direction on the same socket. The executor sends
  `{"rid", "method", "params"}` to open a session or run a prompt on behalf of the
  editor a human is watching, and this side answers `{"rid", "result" | "error"}`;
  session updates for a relayed session go down as `{"event": "session/update"}`.
  """

  @behaviour :cowboy_websocket

  alias TaskweftAcp.Executor.Registry
  alias TaskweftAcpDeploy.Auth

  @policy "taskweft-acp-executor"
  @request_timeout 30_000

  @doc "Send one session update down to a relaying executor."
  @spec update(pid(), map()) :: :ok
  def update(pid, params) do
    send(pid, {:session_update, params})
    :ok
  end

  @doc "Ask the executor behind `pid` to perform `method`; blocks the caller."
  @spec request(pid(), String.t(), map(), timeout()) :: {:ok, term()} | {:error, term()}
  def request(pid, method, params, timeout \\ @request_timeout) do
    ref = make_ref()
    send(pid, {:request, {self(), ref}, method, params})

    receive do
      {^ref, {:ok, result}} -> {:ok, result}
      {^ref, {:error, reason}} -> {:error, reason}
    after
      timeout -> {:error, :executor_timeout}
    end
  end

  @impl :cowboy_websocket
  def init(req, _opts) do
    qs = :cowboy_req.parse_qs(req)
    token = bearer(req) || value(qs, "token")
    name = value(qs, "name")
    labels = qs |> value("labels") |> to_string() |> String.split(",", trim: true)

    case {name, Auth.check(token, @policy)} do
      {nil, _} ->
        {:ok, :cowboy_req.reply(400, %{}, ~s({"error":"name is required"}), req), nil}

      {_, {:error, reason}} ->
        status = if reason == :unreachable, do: 503, else: 401

        {:ok, :cowboy_req.reply(status, %{}, Jason.encode!(%{error: to_string(reason)}), req),
         nil}

      {name, {:ok, info}} ->
        {:cowboy_websocket, req,
         %{name: name, labels: labels, principal: info.display, pending: %{}, next: 1},
         %{idle_timeout: 3_600_000}}
    end
  end

  @impl :cowboy_websocket
  def websocket_init(state) do
    :ok = Registry.register(state.name, state.labels, self())

    {[{:text, Jason.encode!(%{event: "registered", name: state.name, labels: state.labels})}],
     state}
  end

  @impl :cowboy_websocket
  def websocket_handle({:text, frame}, state) do
    case Jason.decode(frame) do
      {:ok, %{"id" => id, "result" => result}} ->
        {[], answer(state, id, {:ok, result})}

      {:ok, %{"id" => id, "error" => error}} ->
        {[], answer(state, id, {:error, error})}

      {:ok, %{"rid" => rid, "method" => method} = frame} ->
        relay(state, rid, method, frame["params"] || %{})

      {:ok, %{"event" => "ping"}} ->
        {[{:text, ~s({"event":"pong"})}], state}

      _ ->
        {[{:text, ~s({"error":"unreadable frame"})}], state}
    end
  end

  def websocket_handle(_other, state), do: {[], state}

  @impl :cowboy_websocket
  def websocket_info({:relay_reply, rid, reply}, state) do
    frame =
      case reply do
        {:ok, result} -> %{rid: rid, result: result}
        {:error, reason} -> %{rid: rid, error: inspect(reason)}
      end

    {[{:text, Jason.encode!(frame)}], state}
  end

  def websocket_info({:session_update, params}, state),
    do: {[{:text, Jason.encode!(%{event: "session/update", params: params})}], state}

  def websocket_info({:request, from, method, params}, state) do
    id = state.next
    frame = Jason.encode!(%{id: id, method: method, params: params})
    {[{:text, frame}], %{state | pending: Map.put(state.pending, id, from), next: id + 1}}
  end

  def websocket_info(_other, state), do: {[], state}

  @impl :cowboy_websocket
  def terminate(_reason, _req, %{pending: pending}) do
    for {_id, {pid, ref}} <- pending, do: send(pid, {ref, {:error, :executor_disconnected}})
    :ok
  end

  def terminate(_reason, _req, _state), do: :ok

  # A relayed call can run for the length of a prompt, so it must not block the socket.
  defp relay(state, rid, method, params) do
    socket = self()
    name = state.name

    {:ok, _} =
      Task.start(fn -> send(socket, {:relay_reply, rid, serve_relay(name, method, params)}) end)

    {[], state}
  end

  @doc false
  @spec serve_relay(String.t(), String.t(), map()) :: {:ok, term()} | {:error, term()}
  def serve_relay(name, "session/new", params) do
    case TaskweftAcp.Bridge.new_session(TaskweftAcp.Bridge, params["cwd"], executor: name) do
      {:ok, id} -> {:ok, %{"sessionId" => id}}
      {:error, _} = e -> e
    end
  end

  def serve_relay(_name, "session/prompt", params) do
    TaskweftAcp.Bridge.prompt(TaskweftAcp.Bridge, params["sessionId"], params["text"])
  end

  def serve_relay(_name, "session/list", _params) do
    case TaskweftAcp.Bridge.sessions(TaskweftAcp.Bridge) do
      {:ok, rows} -> {:ok, %{"sessions" => rows}}
      {:error, _} = e -> e
    end
  end

  def serve_relay(_name, "session/cancel", params) do
    :ok = TaskweftAcp.Bridge.cancel(TaskweftAcp.Bridge, params["sessionId"])
    {:ok, %{}}
  end

  def serve_relay(_name, "session/close", params) do
    case TaskweftAcp.Bridge.close(TaskweftAcp.Bridge, params["sessionId"]) do
      :ok -> {:ok, %{}}
      {:error, _} = e -> e
    end
  end

  def serve_relay(_name, method, _params), do: {:error, "unsupported #{method}"}

  defp answer(state, id, reply) do
    case Map.pop(state.pending, id) do
      {nil, pending} ->
        %{state | pending: pending}

      {{pid, ref}, pending} ->
        send(pid, {ref, reply})
        %{state | pending: pending}
    end
  end

  defp bearer(req) do
    case :cowboy_req.header("authorization", req) do
      "Bearer " <> token -> String.trim(token)
      _ -> nil
    end
  end

  defp value(qs, key) do
    case List.keyfind(qs, key, 0) do
      {_, v} when is_binary(v) -> v
      _ -> nil
    end
  end
end
