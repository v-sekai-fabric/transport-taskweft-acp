# Copyright (c) 2026 K. S. Ernest (iFire) Lee
# SPDX-License-Identifier: MIT

defmodule TaskweftAcp.Effects do
  @moduledoc """
  The three editor-facing primitives a plan step can need. The ACP implementation asks the
  client; a test double answers from a script.
  """

  @type ctx :: %{agent: pid() | nil, session_id: String.t(), cwd: String.t()}

  @callback read_file(ctx(), String.t()) :: {:ok, String.t()} | {:error, term()}
  @callback write_file(ctx(), String.t(), String.t()) ::
              {:ok, String.t() | nil} | {:error, term()}
  @callback run_command(ctx(), String.t(), [String.t()]) ::
              {:ok, %{exit_code: integer(), output: String.t()}} | {:error, term()}
end
