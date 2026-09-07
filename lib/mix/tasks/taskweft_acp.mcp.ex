# Copyright (c) 2026 K. S. Ernest (iFire) Lee
# SPDX-License-Identifier: MIT

defmodule Mix.Tasks.TaskweftAcp.Mcp do
  @shortdoc "The Claude Code door: MCP over stdio, driving the ACP agent in-VM"
  @moduledoc """
      mix taskweft_acp.mcp

  Register it with `claude mcp add`; the README shows the command. JSON-RPC on stdout,
  everything else on stderr.
  """
  use Mix.Task

  @impl true
  def run(_args) do
    Application.put_env(:ex_mcp, :stdio_mode, true)
    Logger.configure(level: :emergency)
    _ = :logger.set_primary_config(:level, :emergency)
    Mix.Task.run("app.start")
    {:ok, _} = TaskweftAcp.Session.Store.start_link([])
    {:ok, _} = TaskweftAcp.Bridge.start_link([])
    {:ok, _} = ExMCP.Server.StdioServer.start_link(module: TaskweftAcp.Bridge.McpServer)
    Process.sleep(:infinity)
  end
end
