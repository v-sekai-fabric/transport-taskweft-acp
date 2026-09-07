# Copyright (c) 2026 K. S. Ernest (iFire) Lee
# SPDX-License-Identifier: MIT

defmodule TaskweftAcp.Export do
  @moduledoc """
  The decompile: a session's executed prefix as a shell script that re-runs the same
  commands without the agent. A step that failed or was refused becomes a comment naming
  the reason, so the script stops where the run stopped.
  """

  alias TaskweftAcp.{Domain, Session}

  @spec script(Session.t()) :: String.t()
  def script(%Session{} = session) do
    steps = Session.steps(session)
    outcomes = outcomes(session)

    lines =
      steps
      |> Enum.with_index()
      |> Enum.map(fn {[action | args], i} ->
        exec = binding(session, action, args)
        status = Map.get(outcomes, i, "not run")
        line(i, action, exec, status)
      end)

    header = [
      "#!/bin/sh",
      "# taskweft-acp session #{session.id}, exported #{Session.now()}",
      "# #{length(steps)} planned step(s), #{session.executed_prefix} executed; a failed or unrun step is a comment.",
      "set -e",
      "cd #{sh_quote(session.cwd || ".")}"
    ]

    body = if lines == [], do: ["# no steps were planned in this session"], else: lines
    Enum.join(header ++ [""] ++ body, "\n") <> "\n"
  end

  defp line(i, action, %{kind: :terminal} = exec, "completed") do
    "# step #{i} #{action}\n" <> Enum.map_join([exec.command | exec.args], " ", &sh_quote/1)
  end

  defp line(i, action, %{kind: :read} = exec, "completed"),
    do: "# step #{i} #{action}\ncat #{sh_quote(exec.path)}"

  defp line(i, action, %{kind: :write} = exec, "completed") do
    content = Map.get(exec, :content, "")

    "# step #{i} #{action}\ncat > #{sh_quote(exec.path)} <<'TASKWEFT_ACP'\n#{content}\nTASKWEFT_ACP"
  end

  defp line(i, action, _exec, status), do: "# step #{i} #{action}: #{status}"

  defp outcomes(session), do: session.step_status

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

  defp sh_quote(s) when is_binary(s) do
    if Regex.match?(~r/^[A-Za-z0-9_\/.=:@%+,-]+$/, s),
      do: s,
      else: "'" <> String.replace(s, "'", "'\\''") <> "'"
  end
end
