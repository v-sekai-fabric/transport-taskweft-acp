# Copyright (c) 2026 K. S. Ernest (iFire) Lee
# SPDX-License-Identifier: MIT

defmodule TaskweftAcp.Executor.Policy do
  @moduledoc """
  What an executor will run without asking. The policy comes from OpenBao (the
  `taskweft_acp_policy` field of the executor's own `agents/<cn>` secret, read with its
  token) and a local `.taskweft-acp/policy.exs` overrides it key by key. An action in
  neither list is rejected and named; the answer is produced here, never on the hosted
  side.
  """

  @type t :: %{allow_always: [String.t()], reject: [String.t()], ask: [String.t()]}

  @empty %{allow_always: [], reject: [], ask: []}

  @spec load(String.t(), keyword()) :: t()
  def load(cwd, opts \\ []) do
    from_bao = Keyword.get(opts, :bao, %{}) |> normalize()
    Map.merge(from_bao, local(cwd), fn _k, _bao, local -> local end)
  end

  @doc "Read the bao-held policy with the executor's token; absent is an empty policy, unreachable is an error."
  @spec from_bao(String.t(), String.t(), String.t()) :: {:ok, t()} | {:error, term()}
  def from_bao(bao_addr, token, cn) do
    url = "#{bao_addr}/v1/agents/data/#{cn}"

    case Req.get(url, headers: [{"x-vault-token", token}], receive_timeout: 5_000) do
      {:ok, %{status: 200, body: %{"data" => %{"data" => data}}}} ->
        case data["taskweft_acp_policy"] do
          nil -> {:ok, @empty}
          text when is_binary(text) -> {:ok, parse(text)}
          map when is_map(map) -> {:ok, normalize(map)}
        end

      {:ok, %{status: 404}} ->
        {:ok, @empty}

      {:ok, %{status: status}} ->
        {:error, {:bao, status}}

      {:error, reason} ->
        {:error, {:bao, reason}}
    end
  end

  @doc "The answer for one action: allow-always, allow-once (listed under ask) or reject-once."
  @spec decide(t(), String.t()) :: String.t()
  def decide(policy, action) do
    cond do
      action in policy.reject -> "reject-once"
      action in policy.allow_always -> "allow-always"
      action in policy.ask -> "allow-once"
      true -> "reject-once"
    end
  end

  defp local(cwd) do
    path = Path.join(TaskweftAcp.workspace_dir(cwd), "policy.exs")

    if File.exists?(path), do: path |> File.read!() |> parse(), else: %{}
  end

  @doc false
  def parse(text) do
    with {:ok, ast} <- Code.string_to_quoted(text),
         map when is_map(map) <- literal(ast) do
      normalize(map)
    else
      _ -> %{}
    end
  end

  defp normalize(map) when is_map(map) do
    for {k, v} <- map, key = to_atom(k), key in [:allow_always, :reject, :ask], into: %{} do
      {key, Enum.map(List.wrap(v), &to_string/1)}
    end
  end

  defp to_atom(a) when is_atom(a), do: a
  defp to_atom(s) when is_binary(s), do: String.to_atom(s)

  defp literal({:%{}, _, pairs}), do: Map.new(pairs, fn {k, v} -> {literal(k), literal(v)} end)
  defp literal(list) when is_list(list), do: Enum.map(list, &literal/1)
  defp literal(v) when is_atom(v) or is_binary(v) or is_number(v), do: v
  defp literal(_), do: :invalid
end
