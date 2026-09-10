# Copyright (c) 2026 K. S. Ernest (iFire) Lee
# SPDX-License-Identifier: MIT

defmodule TaskweftAcp.MixProject do
  use Mix.Project

  def project do
    [
      app: :taskweft_acp,
      version: "0.1.0",
      elixir: "~> 1.20",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      releases: [taskweft_acp_deploy: [include_executables_for: [:unix]]],
      dialyzer: [
        plt_add_apps: [:mix, :ex_unit],
        plt_file: {:no_warn, "priv/plts/taskweft_acp.plt"},
        ignore_warnings: ".dialyzer_ignore.exs",
        flags: [:error_handling, :underspecs, :unmatched_returns]
      ]
    ]
  end

  def application do
    [extra_applications: [:logger], mod: {TaskweftAcp.Application, []}]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:ex_mcp, "1.0.0-rc.4"},
      {:jason, "~> 1.4"},
      taskweft_dep(),
      {:plug_cowboy, "~> 2.7"},
      {:websock_adapter, "~> 0.5"},
      {:mint_web_socket, "~> 1.0"},
      {:req, "~> 0.5"},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  # TASKWEFT_PATH points a desk at its own checkout; the git dependency is the default.
  defp taskweft_dep do
    case System.get_env("TASKWEFT_PATH") do
      nil -> {:taskweft, git: "https://github.com/V-Sekai-fire/interactor-taskweft.git", branch: "main"}
      path -> {:taskweft, path: path}
    end
  end
end
