# Copyright (c) 2026 K. S. Ernest (iFire) Lee
# SPDX-License-Identifier: MIT

defmodule TaskweftAcp.Planner do
  @moduledoc """
  The domain plus the session's todo list, composed and planned by taskweft; a failed step
  replans from the verified prefix.
  """

  alias TaskweftAcp.Domain

  @type plan :: %{String.t() => term()}

  @spec plan(Domain.t(), [[String.t()]]) :: {:ok, plan()} | {:error, String.t()}
  def plan(%Domain{} = domain, todo) do
    with {:ok, json} <- compose(domain, todo),
         {:ok, _} <- validate(json),
         {:ok, result} <- run_plan(json) do
      {:ok, result}
    end
  end

  @spec replan(Domain.t(), [[String.t()]], plan(), non_neg_integer()) ::
          {:ok, plan()} | {:error, String.t()}
  def replan(%Domain{} = domain, todo, plan, fail_step) do
    steps_json = Jason.encode!(plan["plan"] || [])

    with {:ok, json} <- compose(domain, todo),
         {:ok, text} <- call(fn -> Taskweft.replan(json, steps_json, fail_step) end),
         {:ok, envelope} <- Jason.decode(text),
         {:ok, rest} <- recovered(envelope, fail_step) do
      completed = envelope["completed_steps"] || 0
      steps = Enum.take(plan["plan"] || [], completed) ++ rest
      {:ok, Map.merge(plan, %{"plan" => steps, "completed_steps" => completed})}
    else
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, "replan failed: #{inspect(reason)}"}
    end
  end

  # taskweft forbids the failed action and plans the rest from the state after the
  # verified prefix; `recovered: false` means no other decomposition reaches the goal.
  defp recovered(%{"recovered" => true, "new_plan" => rest}, _fail) when is_list(rest),
    do: {:ok, rest}

  defp recovered(_envelope, fail_step),
    do:
      {:error, "no recovery plan from step #{fail_step}: no other decomposition reaches the goal"}

  @doc "ACP plan entries: the executed prefix completed, the current step in progress."
  @spec entries([[String.t()]], non_neg_integer(), non_neg_integer() | nil) :: [map()]
  def entries(steps, executed_prefix, current) do
    steps
    |> Enum.with_index()
    |> Enum.map(fn {step, i} ->
      status =
        cond do
          i < executed_prefix -> "completed"
          i == current -> "in_progress"
          true -> "pending"
        end

      %{"content" => Enum.join(step, " "), "priority" => "medium", "status" => status}
    end)
  end

  @doc "The composed JSON-LD of the domain with the todo list as an overlay."
  @spec compose(Domain.t(), [[String.t()]]) :: {:ok, String.t()} | {:error, String.t()}
  def compose(%Domain{source: source}, todo) do
    overlay = """
    defmodule TaskweftAcpOverlay do
      use Taskweft.DSL
      @name "overlay"
      @todo_list #{inspect(todo, limit: :infinity)}
    end
    """

    case Taskweft.Compose.compose_strings([source, overlay], format: "dsl") do
      {:ok, json} -> {:ok, json}
      {:error, reason} -> {:error, "compose failed: #{inspect(reason)}"}
    end
  end

  defp validate(json) do
    case Taskweft.JSONLD.Loader.load_string(json) do
      {:ok, _} = ok -> ok
      {:error, reason} -> {:error, "domain is invalid: #{inspect(reason)}"}
    end
  end

  defp run_plan(json) do
    with {:ok, text} <- call(fn -> Taskweft.plan_explain(json) end),
         {:ok, result} <- Jason.decode(text) do
      {:ok, result}
    else
      {:error, "no_plan"} -> {:error, "no plan reaches the goal from the current state"}
      {:error, reason} -> {:error, "plan failed: #{inspect(reason)}"}
    end
  end

  defp call(fun) do
    case fun.() do
      {:ok, text} when is_binary(text) -> {:ok, text}
      {:error, _} = e -> e
    end
  end
end
