# Copyright (c) 2026 K. S. Ernest (iFire) Lee
# SPDX-License-Identifier: MIT

defmodule TaskweftAcp.Domain do
  @moduledoc """
  A taskweft DSL domain plus the `@exec` bindings that say how each action reaches the
  editor. taskweft compiles the domain; the bindings are read by a literal AST walk of
  the same file, never by evaluating it.
  """

  defstruct source: "", json: "", exec: %{}, path: nil

  @type exec :: %{
          kind: :terminal | :read | :write,
          command: String.t() | nil,
          args: [String.t()],
          path: String.t() | nil,
          requires: String.t() | nil
        }
  @type t :: %__MODULE__{source: String.t(), json: String.t(), exec: %{String.t() => exec}}

  def builtin_path, do: builtin_file()

  def builtin, do: load(File.read!(builtin_file()), builtin_file())

  @spec load(String.t(), String.t() | nil) :: {:ok, t()} | {:error, String.t()}
  def load(source, path \\ nil) do
    with {:ok, json} <- Taskweft.DSL.compile(source),
         {:ok, exec} <- extract_exec(source) do
      {:ok, %__MODULE__{source: source, json: json, exec: exec, path: path}}
    else
      {:error, reason} -> {:error, diagnostics(reason)}
    end
  end

  @doc "The `@exec` map of the source, or an empty map when the file has none."
  @spec extract_exec(String.t()) :: {:ok, %{String.t() => exec}} | {:error, String.t()}
  def extract_exec(source) do
    with {:ok, ast} <- Code.string_to_quoted(source) do
      {_, found} =
        Macro.prewalk(ast, nil, fn
          {:@, _, [{:exec, _, [value]}]} = node, _ -> {node, value}
          node, acc -> {node, acc}
        end)

      case found do
        nil -> {:ok, %{}}
        value -> {:ok, value |> literal() |> normalize_exec()}
      end
    else
      {:error, {meta, message, token}} ->
        {:error, "line #{Keyword.get(meta, :line, 0)}: #{message}#{token}"}
    end
  rescue
    e in ArgumentError -> {:error, "@exec is not a literal: " <> Exception.message(e)}
  end

  @doc "A per-workspace `.taskweft-acp/config.exs` overlay, deep-merged over `exec`."
  @spec apply_overlay(%{String.t() => exec}, String.t()) :: %{String.t() => exec}
  def apply_overlay(exec, cwd) do
    path = Path.join(TaskweftAcp.workspace_dir(cwd), "config.exs")

    with true <- File.exists?(path),
         {:ok, ast} <- Code.string_to_quoted(File.read!(path)),
         %{exec: overlay} <- literal(ast) do
      merge_overlay(exec, overlay)
    else
      _ -> exec
    end
  end

  # Only the keys the overlay names change; a new action gets the full shape.
  defp merge_overlay(exec, overlay) when is_map(overlay) do
    empty = %{kind: :terminal, command: nil, args: [], path: nil, requires: nil}

    Enum.reduce(overlay, exec, fn
      {action, spec}, acc when is_map(spec) ->
        over = Map.new(spec, fn {k, v} -> {to_atom(k), coerce(to_atom(k), v)} end)
        Map.update(acc, to_string(action), Map.merge(empty, over), &Map.merge(&1, over))

      _, acc ->
        acc
    end)
  end

  defp coerce(:kind, v), do: to_atom(v)
  defp coerce(:args, v) when is_list(v), do: Enum.map(v, &to_string/1)
  defp coerce(_k, v), do: v

  @doc "Substitute `{param}` placeholders; an argument that is exactly a placeholder becomes the value."
  @spec bind(exec, %{String.t() => term()}) :: exec
  def bind(exec, args) do
    sub = fn
      nil ->
        nil

      s when is_binary(s) ->
        Regex.replace(~r/\{(\w+)\}/, s, fn _, k -> to_string(args[k] || "{#{k}}") end)
    end

    %{
      exec
      | command: sub.(exec.command),
        args: Enum.map(exec.args, sub),
        path: sub.(exec.path)
    }
  end

  @doc "The action names, in the order the source declares them, with their parameter names."
  @spec params(t()) :: %{String.t() => [String.t()]}
  def params(%__MODULE__{json: json}) do
    doc = Jason.decode!(json)

    for {name, action} <- Map.get(doc, "actions", %{}), into: %{} do
      {name, Enum.map(Map.get(action, "params", []), &to_string/1)}
    end
  end

  defp normalize_exec(map) when is_map(map) do
    for {action, spec} <- map, into: %{} do
      spec = Map.new(spec, fn {k, v} -> {to_atom(k), v} end)

      {to_string(action),
       %{
         kind: to_atom(spec[:kind]),
         command: spec[:command],
         args: Enum.map(spec[:args] || [], &to_string/1),
         path: spec[:path],
         requires: spec[:requires]
       }}
    end
  end

  defp to_atom(a) when is_atom(a), do: a
  defp to_atom(s) when is_binary(s), do: String.to_atom(s)

  # Literal maps, lists, atoms, strings, numbers and booleans only.
  defp literal({:%{}, _, pairs}), do: Map.new(pairs, fn {k, v} -> {literal(k), literal(v)} end)
  defp literal(list) when is_list(list), do: Enum.map(list, &literal/1)
  defp literal({a, b}), do: {literal(a), literal(b)}
  defp literal(v) when is_atom(v) or is_binary(v) or is_number(v), do: v
  defp literal(other), do: raise(ArgumentError, "unsupported term #{Macro.to_string(other)}")

  defp diagnostics(reason) when is_binary(reason), do: reason

  defp builtin_file, do: Path.join(:code.priv_dir(:taskweft_acp), "domains/repo_chores.ex")
end
