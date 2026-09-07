# Copyright (c) 2026 K. S. Ernest (iFire) Lee
# SPDX-License-Identifier: MIT

defmodule TaskweftAcp.Executor.Socket do
  @moduledoc """
  The executor's end of the `/executor` WebSocket: an outbound Mint connection that
  registers the executor, answers every server request through `handler.(method,
  params)`, and reconnects with backoff when the hosted side goes away.

  The socket carries both directions. A server request arrives as `{"id", "method",
  "params"}` and is answered `{"id", "result" | "error"}`; a request this side makes
  (relay editor mode) goes out as `{"rid", "method", "params"}` and comes back
  `{"rid", "result" | "error"}`. The two key names keep the numbering spaces apart.
  """

  use GenServer
  require Logger

  defstruct [
    :url,
    :token,
    :name,
    :labels,
    :handler,
    :conn,
    :websocket,
    :ref,
    :backoff,
    :updates,
    pending: %{},
    next_rid: 1,
    status: :connecting
  ]

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name_proc))

  @doc "Ask the hosted door to do something; blocks the caller until it answers."
  @spec request(GenServer.server(), String.t(), map(), timeout()) ::
          {:ok, term()} | {:error, term()}
  def request(socket, method, params, timeout \\ 300_000),
    do: GenServer.call(socket, {:request, method, params}, timeout)

  @impl true
  def init(opts) do
    state = %__MODULE__{
      url: Keyword.fetch!(opts, :url),
      token: Keyword.fetch!(opts, :token),
      name: Keyword.fetch!(opts, :name),
      labels: Keyword.get(opts, :labels, []),
      handler: Keyword.fetch!(opts, :handler),
      updates: Keyword.get(opts, :updates),
      backoff: 1_000
    }

    {:ok, state, {:continue, :connect}}
  end

  @impl true
  def handle_continue(:connect, state) do
    case connect(state) do
      {:ok, state} ->
        Logger.info("executor #{state.name} connected to #{state.url}")
        {:noreply, %{state | status: :connected, backoff: 1_000}}

      {:error, reason} ->
        Logger.warning(
          "executor #{state.name}: #{inspect(reason)}; retrying in #{state.backoff} ms"
        )

        Process.send_after(self(), :reconnect, state.backoff)
        {:noreply, %{state | status: :connecting, backoff: min(state.backoff * 2, 30_000)}}
    end
  end

  @impl true
  def handle_call({:request, _method, _params}, _from, %{websocket: nil} = state),
    do: {:reply, {:error, :not_connected}, state}

  def handle_call({:request, method, params}, from, state) do
    rid = state.next_rid
    frame = {:text, Jason.encode!(%{rid: rid, method: method, params: params})}

    {:noreply,
     %{
       send_frame(state, frame)
       | pending: Map.put(state.pending, rid, from),
         next_rid: rid + 1
     }}
  end

  @impl true
  def handle_info(:reconnect, state), do: {:noreply, state, {:continue, :connect}}

  def handle_info(message, %{conn: conn} = state) when conn != nil do
    case Mint.WebSocket.stream(conn, message) do
      {:ok, conn, responses} ->
        state = %{state | conn: conn}
        {:noreply, Enum.reduce(responses, state, &handle_response/2)}

      {:error, conn, reason, _responses} ->
        Logger.warning("executor #{state.name}: connection lost: #{inspect(reason)}")
        _ = Mint.HTTP.close(conn)
        Process.send_after(self(), :reconnect, state.backoff)
        {:noreply, %{state | conn: nil, websocket: nil, status: :connecting}}

      :unknown ->
        {:noreply, state}
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp handle_response({:data, ref, data}, %{ref: ref} = state) do
    case Mint.WebSocket.decode(state.websocket, data) do
      {:ok, websocket, frames} ->
        Enum.reduce(frames, %{state | websocket: websocket}, &handle_frame/2)

      {:error, websocket, reason} ->
        Logger.warning("executor #{state.name}: bad frame: #{inspect(reason)}")
        %{state | websocket: websocket}
    end
  end

  defp handle_response(_other, state), do: state

  defp handle_frame({:text, text}, state) do
    case Jason.decode(text) do
      {:ok, %{"id" => id, "method" => method, "params" => params}} ->
        reply =
          try do
            case state.handler.(method, params) do
              {:ok, result} -> %{id: id, result: result}
              {:error, reason} -> %{id: id, error: to_string(reason)}
            end
          rescue
            e -> %{id: id, error: Exception.message(e)}
          end

        send_frame(state, {:text, Jason.encode!(reply)})

      {:ok, %{"rid" => rid} = reply} ->
        answer(state, rid, reply)

      {:ok, %{"event" => "session/update", "params" => params}} ->
        if state.updates, do: state.updates.(params)
        state

      {:ok, %{"event" => event}} ->
        Logger.debug("executor #{state.name}: #{event}")
        state

      _ ->
        state
    end
  end

  defp handle_frame({:close, _code, _reason}, state) do
    Process.send_after(self(), :reconnect, state.backoff)
    for {_rid, from} <- state.pending, do: GenServer.reply(from, {:error, :disconnected})
    %{state | conn: nil, websocket: nil, pending: %{}, status: :connecting}
  end

  defp handle_frame(_other, state), do: state

  defp answer(state, rid, reply) do
    case Map.pop(state.pending, rid) do
      {nil, pending} ->
        %{state | pending: pending}

      {from, pending} ->
        GenServer.reply(from, reply_of(reply))
        %{state | pending: pending}
    end
  end

  defp reply_of(%{"error" => error}), do: {:error, error}
  defp reply_of(%{"result" => result}), do: {:ok, result}
  defp reply_of(other), do: {:error, {:unreadable_reply, other}}

  defp send_frame(state, frame) do
    with {:ok, websocket, data} <- Mint.WebSocket.encode(state.websocket, frame),
         {:ok, conn} <- Mint.WebSocket.stream_request_body(state.conn, state.ref, data) do
      %{state | websocket: websocket, conn: conn}
    else
      {:error, _, reason} ->
        Logger.warning("executor #{state.name}: send failed: #{inspect(reason)}")
        state
    end
  end

  defp connect(state) do
    uri = URI.parse(state.url)
    scheme = if uri.scheme in ["wss", "https"], do: :https, else: :http
    ws_scheme = if scheme == :https, do: :wss, else: :ws
    query = URI.encode_query(%{"name" => state.name, "labels" => Enum.join(state.labels, ",")})
    path = (uri.path || "/executor") <> "?" <> query

    port = uri.port || if(scheme == :https, do: 443, else: 80)

    with {:ok, conn} <- Mint.HTTP.connect(scheme, uri.host, port, protocols: [:http1]),
         {:ok, conn, ref} <-
           Mint.WebSocket.upgrade(ws_scheme, conn, path, [
             {"authorization", "Bearer " <> state.token}
           ]),
         {:ok, conn, websocket} <- await_upgrade(conn, ref) do
      {:ok, %{state | conn: conn, websocket: websocket, ref: ref}}
    else
      {:error, reason} -> {:error, reason}
      {:error, _conn, reason} -> {:error, reason}
    end
  end

  defp await_upgrade(conn, ref) do
    receive do
      message ->
        case Mint.WebSocket.stream(conn, message) do
          {:ok, conn, responses} ->
            status = for {:status, ^ref, s} <- responses, do: s
            headers = for {:headers, ^ref, h} <- responses, do: h

            case {status, headers} do
              {[101], [h | _]} -> Mint.WebSocket.new(conn, ref, 101, h)
              {[s], _} -> {:error, {:upgrade_refused, s}}
              _ -> await_upgrade(conn, ref)
            end

          {:error, _conn, reason, _} ->
            {:error, reason}

          :unknown ->
            await_upgrade(conn, ref)
        end
    after
      10_000 -> {:error, :upgrade_timeout}
    end
  end
end
