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

  # Liveness for the platform's check: the release is up. Readiness is /health.
  get "/live" do
    send_resp(conn, 200, "ok")
  end

  get "/health" do
    store =
      try do
        %{adapter: adapter, mode: mode} = Store.status()
        store_health(inspect(adapter), mode)
      catch
        :exit, _ -> %{adapter: "none", mode: "down", reason: "store not running"}
      end

    healthy = store.mode in ["primary", "fallback"]
    executors = TaskweftAcp.Executor.Registry.all() |> Enum.map(& &1.name)

    body = %{
      status: if(healthy, do: "ok", else: "degraded"),
      version: @version,
      store: store,
      executors: executors
    }

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(if(healthy, do: 200, else: 503), Jason.encode!(body))
  end

  defp store_health(adapter, :primary), do: %{adapter: adapter, mode: "primary"}
  defp store_health(adapter, :fallback), do: %{adapter: adapter, mode: "fallback"}

  defp store_health(adapter, {:degraded, reason}),
    do: %{adapter: adapter, mode: "degraded", reason: inspect(reason)}

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
