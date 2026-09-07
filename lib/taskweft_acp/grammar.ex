# Copyright (c) 2026 K. S. Ernest (iFire) Lee
# SPDX-License-Identifier: MIT

defmodule TaskweftAcp.Grammar do
  @moduledoc """
  The deterministic front door. A prompt is a slash command or plain text matched against
  the repo-chores method names; nothing is inferred, and text that matches nothing gets
  the command list back.
  """

  alias TaskweftAcp.Intent

  @commands [
    {"domain", "Load a taskweft DSL domain from a file in the workspace", "path"},
    {"goal", "Set goals as name=value pairs", "tests_pass=true"},
    {"task", "Append a task to the todo list", "name args..."},
    {"plan", "Plan only, and show the explain tree", nil},
    {"run", "Plan and execute, step by step, with your permission", "tests pass"},
    {"replan", "Replan from the last failed step", nil},
    {"status", "Show the session's domain, goals, plan and executed prefix", nil},
    {"explain", "Show the last plan's explain tree", nil},
    {"export", "The executed steps as a shell script you can run without the agent", nil},
    {"help", "List these commands", nil}
  ]

  # Ordered: the first match wins. `commit ` keeps the rest of the line as the message.
  @keywords [
    {"commit ", :commit},
    {"test", "tests_pass"},
    {"format", "formatted"},
    {"fmt", "formatted"},
    {"build", "built"},
    {"compile", "built"}
  ]

  @spec parse(String.t()) :: {:ok, Intent.t()} | {:error, {:unknown_command, String.t()}}
  def parse(text) when is_binary(text) do
    trimmed = String.trim(text)

    case trimmed do
      "/" <> rest ->
        {cmd, tail} = split_word(rest)
        parse_slash(cmd, tail, trimmed)

      "" ->
        {:ok, %Intent{kind: :help, raw: trimmed}}

      _ ->
        case match_keywords(trimmed) do
          [] -> {:ok, %Intent{kind: :help, raw: trimmed}}
          todo -> {:ok, %Intent{kind: :run, todo: todo, raw: trimmed}}
        end
    end
  end

  @spec parse_slash(String.t(), String.t(), String.t()) ::
          {:ok, Intent.t()} | {:error, {:unknown_command, String.t()}}
  def parse_slash("domain", path, raw) when path != "",
    do: {:ok, %Intent{kind: :domain, path: path, raw: raw}}

  def parse_slash("goal", pairs, raw),
    do: {:ok, %Intent{kind: :goal, goals: parse_goal_pairs(pairs), raw: raw}}

  def parse_slash("task", rest, raw) do
    case String.split(rest) do
      [] -> {:ok, %Intent{kind: :help, raw: raw}}
      call -> {:ok, %Intent{kind: :task, todo: [call], raw: raw}}
    end
  end

  def parse_slash("plan", rest, raw),
    do: {:ok, %Intent{kind: :plan, todo: match_keywords(rest), raw: raw}}

  def parse_slash("run", rest, raw),
    do: {:ok, %Intent{kind: :run, todo: match_keywords(rest), raw: raw}}

  def parse_slash(cmd, _rest, raw) when cmd in ~w(replan status explain export help),
    do: {:ok, %Intent{kind: String.to_existing_atom(cmd), raw: raw}}

  def parse_slash(cmd, _rest, _raw), do: {:error, {:unknown_command, "/" <> cmd}}

  @doc ~S|`"a=true b=3 c=hello"` becomes `[{"a", true}, {"b", 3}, {"c", "hello"}]`.|
  @spec parse_goal_pairs(String.t()) :: [{String.t(), term()}]
  def parse_goal_pairs(text) do
    for pair <- String.split(text), [k, v] <- [String.split(pair, "=", parts: 2)] do
      {k, value(v)}
    end
  end

  @doc "Plain text to todo calls on the repo-chores methods; `[]` when nothing matches."
  @spec match_keywords(String.t()) :: [[String.t()]]
  def match_keywords(text) do
    lower = String.downcase(String.trim(text))

    Enum.find_value(@keywords, [], fn
      {"commit ", :commit} ->
        if String.starts_with?(lower, "commit ") do
          msg = text |> String.trim() |> String.slice(7..-1//1) |> String.trim()
          [["committed", msg]]
        end

      {word, method} ->
        if String.contains?(lower, word), do: [[method]]
    end)
  end

  @doc "The ACP `available_commands_update` entries."
  def available_commands do
    for {name, description, hint} <- @commands do
      base = %{"name" => name, "description" => description}
      if hint, do: Map.put(base, "input", %{"hint" => hint}), else: base
    end
  end

  def help_text do
    Enum.map_join(@commands, "\n", fn {name, description, hint} ->
      "/#{name}#{if hint, do: " " <> hint, else: ""}: #{description}"
    end)
  end

  defp split_word(text) do
    case String.split(String.trim(text), ~r/\s+/, parts: 2) do
      [cmd] -> {cmd, ""}
      [cmd, rest] -> {cmd, String.trim(rest)}
    end
  end

  defp value("true"), do: true
  defp value("false"), do: false

  defp value(v) do
    case Integer.parse(v) do
      {n, ""} -> n
      _ -> v
    end
  end
end
