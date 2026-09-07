# Copyright (c) 2026 K. S. Ernest (iFire) Lee
# SPDX-License-Identifier: MIT

defmodule TaskweftAcp.Emit do
  @moduledoc """
  Every `session/update` the agent streams goes through here. A client that has gone
  away turns an update into a logged line, never a crash in the executor.
  """

  require Logger

  alias ExMCP.ACP.Agent

  @spec plan(pid(), String.t(), [map()]) :: :ok
  def plan(agent, sid, entries), do: settle(Agent.plan(agent, sid, entries), sid)

  @spec tool_call(pid(), String.t(), map()) :: :ok
  def tool_call(agent, sid, call), do: settle(Agent.tool_call(agent, sid, call), sid)

  @spec tool_call_update(pid(), String.t(), map()) :: :ok
  def tool_call_update(agent, sid, update),
    do: settle(Agent.tool_call_update(agent, sid, update), sid)

  @spec message(pid(), String.t(), String.t()) :: :ok
  def message(agent, sid, text), do: settle(Agent.agent_message(agent, sid, text), sid)

  @spec thought(pid(), String.t(), String.t()) :: :ok
  def thought(agent, sid, text), do: settle(Agent.agent_thought(agent, sid, text), sid)

  @spec available_commands(pid(), String.t(), [map()]) :: :ok
  def available_commands(agent, sid, commands),
    do: settle(Agent.available_commands(agent, sid, commands), sid)

  @spec session_info(pid(), String.t(), map()) :: :ok
  def session_info(agent, sid, info), do: settle(Agent.session_info(agent, sid, info), sid)

  @spec update(pid(), String.t(), map()) :: :ok
  def update(agent, sid, update), do: settle(Agent.session_update(agent, sid, update), sid)

  defp settle(:ok, _sid), do: :ok

  defp settle({:error, reason}, sid) do
    Logger.debug("session #{sid}: update not delivered: #{inspect(reason)}")
    :ok
  end
end
