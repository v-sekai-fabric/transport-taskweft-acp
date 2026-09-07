# Copyright (c) 2026 K. S. Ernest (iFire) Lee
# SPDX-License-Identifier: MIT

defmodule TaskweftAcp.Application do
  @moduledoc """
  Under plain `mix` tasks nothing starts. The hosted release (`serve: true`) starts the
  session store, the executor registry and the HTTP door; the stdio tasks start what
  they need themselves.
  """

  use Application

  @impl true
  def start(_type, _args) do
    with :ok <- fabric_credentials(), do: start_children()
  end

  # A partial credential set fails the boot; none at all means plain or memory mode.
  defp fabric_credentials do
    case TaskweftAcp.FabricEnv.materialise() do
      {:error, reason} ->
        {:error, {:fabric_credentials, reason}}

      state ->
        :logger.info("fabric credentials: #{state}")
        :ok
    end
  end

  defp start_children do
    children =
      if Application.get_env(:taskweft_acp, :serve, false) do
        [
          {TaskweftAcp.Session.Store, on_unreachable: :degrade},
          TaskweftAcp.Executor.Registry,
          {Plug.Cowboy,
           scheme: :http,
           plug: TaskweftAcpDeploy.Router,
           options: [
             port: Application.get_env(:taskweft_acp, :port, 8080),
             dispatch: TaskweftAcpDeploy.Router.dispatch()
           ]}
        ]
      else
        []
      end

    Supervisor.start_link(children, strategy: :one_for_one, name: TaskweftAcp.Supervisor)
  end
end
