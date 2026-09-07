# Copyright (c) 2026 K. S. Ernest (iFire) Lee
# SPDX-License-Identifier: MIT

defmodule Mix.Tasks.TaskweftAcp.Executor do
  @shortdoc "Dial in to the hosted door as an executor side"
  @moduledoc """
      mix taskweft_acp.executor --remote wss://HOST/executor --name magi [--label gpu:4090] [--cwd DIR]

  The bearer is the executor's own OpenBao token: `TASKWEFT_ACP_TOKEN` or `BAO_TOKEN` in
  the environment (`bao login -no-store -token-only`). The permission policy is the
  `taskweft_acp_policy` field of `agents/<cn>` in bao when `--cn` is given, overridden
  by `.taskweft-acp/policy.exs` under the working directory.
  """
  use Mix.Task

  @impl true
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [remote: :string, name: :string, label: :keep, cwd: :string, cn: :string]
      )

    remote = opts[:remote] || Mix.raise("--remote wss://HOST/executor is required")
    name = opts[:name] || Mix.raise("--name is required")

    token =
      System.get_env("TASKWEFT_ACP_TOKEN") || System.get_env("BAO_TOKEN") ||
        Mix.raise("TASKWEFT_ACP_TOKEN or BAO_TOKEN must carry an OpenBao token")

    labels = Keyword.get_values(opts, :label)
    cwd = opts[:cwd] || File.cwd!()

    Mix.Task.run("app.start")

    bao_policy =
      case {opts[:cn], System.get_env("BAO_ADDR")} do
        {cn, addr} when is_binary(cn) and is_binary(addr) ->
          case TaskweftAcp.Executor.Policy.from_bao(addr, token, cn) do
            {:ok, policy} -> policy
            {:error, reason} -> Mix.raise("bao policy for #{cn}: #{inspect(reason)}")
          end

        _ ->
          %{}
      end

    {:ok, _} =
      TaskweftAcp.Executor.start_link(
        url: remote,
        token: token,
        name: name,
        labels: labels,
        cwd: cwd,
        bao_policy: bao_policy
      )

    Mix.shell().info("executor #{name} serving #{cwd} for #{remote}")
    Process.sleep(:infinity)
  end
end
