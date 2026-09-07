# Copyright (c) 2026 K. S. Ernest (iFire) Lee
# SPDX-License-Identifier: MIT

defmodule TaskweftAcpDeploy.Router do
  @moduledoc """
  The hosted door on Fly: `/health` open, `/mcp` for Claude Code and `/executor` for
  executor sides, both gated by an OpenBao token (never GitHub). `/mcp` is
  `ExMCP.HttpPlug` over the bridge's tools; `/executor` upgrades to the WebSocket an
  executor holds as the ACP client of its session.
  """

  use Plug.Router

  alias TaskweftAcp.Session.Store

  @version Mix.Project.config()[:version]

  plug(Plug.Logger, log: :info)
  plug(:match)
  plug(:dispatch)

  @doc "The Cowboy dispatch: the WebSocket route first, everything else through this router."
  def dispatch do
    [
      {:_,
       [
         {"/executor", TaskweftAcp.Transport.WebSocket, []},
         {:_, Plug.Cowboy.Handler, {__MODULE__, []}}
       ]}
    ]
  end

  get "/health" do
    store =
      try do
        %{adapter: adapter, mode: mode} = Store.status()
        %{adapter: inspect(adapter), mode: mode}
      catch
        :exit, _ -> %{adapter: "none", mode: :down}
      end

    executors = TaskweftAcp.Executor.Registry.all() |> Enum.map(& &1.name)

    body = %{
      status: if(store.mode == :down, do: "degraded", else: "ok"),
      version: @version,
      store: store,
      executors: executors
    }

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(if(store.mode == :down, do: 503, else: 200), Jason.encode!(body))
  end

  forward("/mcp",
    to: TaskweftAcpDeploy.Gated,
    init_opts: [
      policy: "taskweft-acp-user",
      plug: ExMCP.HttpPlug,
      plug_opts: [
        handler: TaskweftAcp.Bridge.McpServer,
        server_info: %{name: "taskweft-acp", version: @version},
        sse_enabled: true,
        cors_enabled: true,
        allowed_origins: :any,
        validate_origin: false
      ]
    ]
  )

  match _ do
    conn |> put_resp_content_type("application/json") |> send_resp(404, ~s({"error":"not found"}))
  end
end
