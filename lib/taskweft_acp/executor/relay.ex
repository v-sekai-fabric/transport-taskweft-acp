# Copyright (c) 2026 K. S. Ernest (iFire) Lee
# SPDX-License-Identifier: MIT

defmodule TaskweftAcp.Executor.Relay do
  @moduledoc """
  The ACP agent an editor talks to in relay mode. It plans nothing: `session/new` and
  `session/prompt` go up the executor's WebSocket to the hosted door, the door's updates
  come back down and are re-emitted here, and every file, terminal and permission request
  the door makes for this session is asked of the editor rather than answered from policy.
  """

  @behaviour ExMCP.ACP.Agent.Handler

  alias TaskweftAcp.Executor.Socket

  @impl true
  def init(opts), do: {:ok, %{socket: Keyword.fetch!(opts, :socket), cwd: nil}}

  @impl true
  def handle_new_session(params, _ctx, st) do
    cwd = params["cwd"] || File.cwd!()

    case Socket.request(st.socket, "session/new", %{"cwd" => cwd}) do
      {:ok, %{"sessionId" => id}} -> {:reply, %{"sessionId" => id}, %{st | cwd: cwd}}
      {:error, reason} -> {:error, {-32_603, "hosted door: #{inspect(reason)}"}, st}
    end
  end

  @impl true
  def handle_prompt(session_id, prompt, ctx, st) do
    text = text_of(prompt)
    socket = st.socket
    agent = ctx.agent
    prompt_id = ctx.prompt_id

    {:ok, _} =
      Task.start(fn ->
        stop =
          case Socket.request(socket, "session/prompt", %{
                 "sessionId" => session_id,
                 "text" => text
               }) do
            {:ok, %{"stopReason" => reason}} -> reason
            {:ok, _} -> "end_turn"
            {:error, _} -> "refusal"
          end

        _ = ExMCP.ACP.Agent.finish_prompt(agent, prompt_id, stop)
      end)

    {:noreply, st}
  end

  @impl true
  def handle_cancel(session_id, _ctx, st) do
    _ = Socket.request(st.socket, "session/cancel", %{"sessionId" => session_id}, 30_000)
    {:noreply, st}
  end

  @impl true
  def handle_close_session(session_id, _ctx, st) when is_binary(session_id) do
    _ = Socket.request(st.socket, "session/close", %{"sessionId" => session_id}, 30_000)
    {:reply, %{}, st}
  end

  @impl true
  def handle_list_sessions(_params, _ctx, st) do
    case Socket.request(st.socket, "session/list", %{}, 30_000) do
      {:ok, %{"sessions" => rows}} -> {:reply, %{"sessions" => rows}, st}
      {:error, reason} -> {:error, {-32_603, "hosted door: #{inspect(reason)}"}, st}
    end
  end

  @impl true
  def terminate(_reason, _st), do: :ok

  defp text_of(prompt) when is_list(prompt) do
    prompt
    |> Enum.filter(&(is_map(&1) and &1["type"] == "text"))
    |> Enum.map_join("\n", & &1["text"])
  end

  defp text_of(prompt) when is_binary(prompt), do: prompt
  defp text_of(_), do: ""
end
