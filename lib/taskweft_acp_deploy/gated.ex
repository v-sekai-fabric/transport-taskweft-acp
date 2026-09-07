# Copyright (c) 2026 K. S. Ernest (iFire) Lee
# SPDX-License-Identifier: MIT

defmodule TaskweftAcpDeploy.Gated do
  @moduledoc false
  @behaviour Plug

  @impl Plug
  def init(opts) do
    %{
      auth: TaskweftAcpDeploy.Auth.init(policy: Keyword.fetch!(opts, :policy)),
      plug: Keyword.fetch!(opts, :plug),
      plug_opts: Keyword.fetch!(opts, :plug).init(Keyword.fetch!(opts, :plug_opts))
    }
  end

  @impl Plug
  def call(conn, %{auth: auth, plug: plug, plug_opts: plug_opts}) do
    conn = TaskweftAcpDeploy.Auth.call(conn, auth)
    if conn.halted, do: conn, else: plug.call(conn, plug_opts)
  end
end
