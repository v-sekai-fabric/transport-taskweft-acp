# Copyright (c) 2026 K. S. Ernest (iFire) Lee
# SPDX-License-Identifier: MIT

defmodule TaskweftAcp.Export do
  @moduledoc """
  The decompile: a session's plan as a SafeGDScript program (`.sgd`) for Godot Sandbox.
  The guest carries the plan and the state machine and can neither shell out nor touch
  files; the host scene under `priv/godot_project/` performs each step the guest asks
  for and reports the exit code back, so the same run replays under the sandbox's own
  permission model. A step that failed or was refused in the session is carried with
  its status and the machine stops where the run stopped.
  """

  alias TaskweftAcp.{Domain, Session}

  @spec sgd(Session.t()) :: String.t()
  def sgd(%Session{} = session) do
    steps = Session.steps(session)
    outcomes = session.step_status

    plan =
      steps
      |> Enum.with_index()
      |> Enum.map_join(",\n", fn {[action | args], i} ->
        exec = binding(session, action, args)
        status = Map.get(outcomes, i, "not run")
        "\t" <> gd_dict(i, action, exec, status)
      end)

    """
    # SafeGDScript, exported by taskweft-acp from session #{session.id} at #{Session.now()}
    # #{length(steps)} planned step(s), #{session.executed_prefix} executed. The host scene
    # (priv/godot_project/main.tscn) loads this program into a Sandbox node and performs
    # each step the guest asks for; the guest only decides what comes next.
    extends Node

    const PLAN := [
    #{plan}
    ]

    var next_step := 0
    var failed_at := -1

    func steps() -> int:
    \treturn PLAN.size()

    func step(i: int) -> Dictionary:
    \treturn PLAN[i]

    # The host calls this with the exit code of the step it just performed.
    func record(i: int, exit_code: int) -> void:
    \tif exit_code == 0:
    \t\tnext_step = i + 1
    \telse:
    \t\tfailed_at = i

    # The next step the host should perform, or -1 when the run is done or stopped.
    func pending() -> int:
    \tif failed_at >= 0 or next_step >= PLAN.size():
    \t\treturn -1
    \tif PLAN[next_step]["status"] != "completed":
    \t\treturn -1
    \treturn next_step
    """
  end

  defp gd_dict(i, action, exec, status) do
    kind = Atom.to_string(exec.kind)
    command = exec.command || ""
    args = Enum.map_join(exec.args, ", ", &gd_string/1)
    path = exec.path || ""

    ~s({"index": #{i}, "action": #{gd_string(action)}, "kind": #{gd_string(kind)}, "command": #{gd_string(command)}, "args": [#{args}], "path": #{gd_string(path)}, "status": #{gd_string(status)}})
  end

  defp gd_string(s) do
    escaped =
      s
      |> to_string()
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")
      |> String.replace("\n", "\\n")

    "\"" <> escaped <> "\""
  end

  defp binding(session, action, args) do
    exec =
      Map.get(session.domain.exec, action, %{
        kind: :terminal,
        command: action,
        args: [],
        path: nil,
        requires: nil
      })

    names = Map.get(Domain.params(session.domain), action, [])
    Domain.bind(exec, Map.new(Enum.zip(names, args)))
  end
end
