# Copyright (c) 2026 K. S. Ernest (iFire) Lee
# SPDX-License-Identifier: MIT

defmodule Mix.Tasks.TaskweftAcp.Agent do
  @shortdoc "The ACP agent over stdio, for an editor"
  @moduledoc """
      mix taskweft_acp.agent

  JSON-RPC on stdout, everything else on stderr. Register it as an ACP agent in the
  editor; the README shows the VS Code setting.
  """
  use Mix.Task

  @impl true
  def run(_args) do
    Application.put_env(:ex_mcp, :stdio_mode, true)
    Logger.configure(level: :emergency)
    _ = :logger.set_primary_config(:level, :emergency)
    Mix.Task.run("app.start", ["--no-compile"])
    {:ok, _} = TaskweftAcp.Session.Store.start_link([])

    :ok =
      ExMCP.ACP.run_agent(
        handler: TaskweftAcp.Agent,
        agent_info: TaskweftAcp.agent_info(),
        transport: :stdio
      )
  end
end
