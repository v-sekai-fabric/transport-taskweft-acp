# Copyright (c) 2026 K. S. Ernest (iFire) Lee
# SPDX-License-Identifier: MIT

defmodule TaskweftAcp.Intent do
  @moduledoc "What one prompt asks for, after the grammar has read it."

  @kinds ~w(domain goal task plan run replan status explain export help)a

  defstruct kind: :help, path: nil, goals: [], todo: [], raw: ""

  @type t :: %__MODULE__{
          kind: atom(),
          path: String.t() | nil,
          goals: [{String.t(), term()}],
          todo: [[String.t()]],
          raw: String.t()
        }

  def kinds, do: @kinds
end
