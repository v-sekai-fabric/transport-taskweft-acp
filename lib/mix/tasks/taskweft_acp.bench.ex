# Copyright (c) 2026 K. S. Ernest (iFire) Lee
# SPDX-License-Identifier: MIT

defmodule Mix.Tasks.TaskweftAcp.Bench do
  @shortdoc "Per-step latency of a ten-step run: the floor, then each store mode"
  @moduledoc """
      mix taskweft_acp.bench [--runs N]

  Prints `TaskweftAcp.Bench.run/1`: the floor row always, plain mode, and fabric mode when
  `WEFT_FDB_CLUSTER_FILE` is set. A row without the floor beside it is not a measurement.
  """
  use Mix.Task

  @impl true
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [runs: :integer])
    Mix.Task.run("app.start")
    Mix.shell().info(TaskweftAcp.Bench.run(opts[:runs] || 5))
  end
end
