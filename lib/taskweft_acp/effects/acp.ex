# Copyright (c) 2026 K. S. Ernest (iFire) Lee
# SPDX-License-Identifier: MIT

defmodule TaskweftAcp.Effects.Acp do
  @moduledoc "Effects through the ACP client: its file system and its terminals."

  @behaviour TaskweftAcp.Effects

  alias ExMCP.ACP.Agent

  @terminal_timeout 600_000

  @impl true
  def read_file(ctx, path) do
    case Agent.read_text_file(ctx.agent, ctx.session_id, absolute(ctx, path)) do
      {:ok, %{"content" => content}} -> {:ok, content}
      {:ok, other} -> {:error, {:unexpected, other}}
      {:error, _} = e -> e
    end
  end

  @impl true
  def write_file(ctx, path, new_text) do
    abs = absolute(ctx, path)

    old =
      case Agent.read_text_file(ctx.agent, ctx.session_id, abs) do
        {:ok, %{"content" => content}} -> content
        _ -> nil
      end

    case Agent.write_text_file(ctx.agent, ctx.session_id, abs, new_text) do
      {:ok, _} -> {:ok, old}
      {:error, _} = e -> e
    end
  end

  @impl true
  def run_command(ctx, command, args) do
    request = %{"command" => command, "args" => args, "cwd" => ctx.cwd}

    with {:ok, %{"terminalId" => id}} <- Agent.terminal_create(ctx.agent, ctx.session_id, request),
         {:ok, exit} <-
           Agent.terminal_wait_for_exit(ctx.agent, ctx.session_id, id, timeout: @terminal_timeout),
         {:ok, out} <- Agent.terminal_output(ctx.agent, ctx.session_id, id) do
      _ = Agent.terminal_release(ctx.agent, ctx.session_id, id)
      {:ok, %{exit_code: exit["exitCode"] || 0, output: out["output"] || ""}}
    else
      {:ok, other} -> {:error, {:unexpected, other}}
      {:error, _} = e -> e
    end
  end

  defp absolute(ctx, path) do
    if Path.type(path) == :absolute, do: path, else: Path.join(ctx.cwd, path)
  end
end
