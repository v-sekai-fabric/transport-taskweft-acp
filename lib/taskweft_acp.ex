# Copyright (c) 2026 K. S. Ernest (iFire) Lee
# SPDX-License-Identifier: MIT

defmodule TaskweftAcp do
  @moduledoc """
  A no-model ACP agent: prompts are a deterministic grammar, plans come from taskweft, and
  every step runs through the ACP client's file system and terminal under its permission.
  """

  @version Mix.Project.config()[:version]

  def version, do: @version

  def agent_info, do: %{"name" => "taskweft-acp", "version" => @version}

  @doc "The per-workspace directory for the plain-mode store and the policy override."
  def workspace_dir(cwd) do
    Path.join(cwd, Application.get_env(:taskweft_acp, :store_dir, ".taskweft-acp"))
  end
end
