# Copyright (c) 2026 K. S. Ernest (iFire) Lee
# SPDX-License-Identifier: MIT

defmodule TaskweftAcp.Run do
  @moduledoc """
  Walk a plan: one ACP tool call per step, the client's permission before it, the effect
  through the client, and a taskweft replan from the verified prefix when a step fails.
  """

  alias ExMCP.ACP.Agent
  alias TaskweftAcp.{Domain, Emit, Planner, Session}

  @max_replans 3

  @permission_options [
    %{"kind" => "allow_once", "name" => "Allow once", "optionId" => "allow-once"},
    %{
      "kind" => "allow_always",
      "name" => "Always allow #{"this action"}",
      "optionId" => "allow-always"
    },
    %{"kind" => "reject_once", "name" => "Reject", "optionId" => "reject-once"},
    %{"kind" => "reject_always", "name" => "Reject and stop", "optionId" => "reject-always"}
  ]

  @type outcome :: :ok | :cancelled | :refusal

  @doc """
  `log` appends an event and returns the session after it; `cancelled?` is read between
  steps; `effects` implements `TaskweftAcp.Effects`.
  """
  @spec run(Session.t(), map(), keyword()) :: {outcome(), Session.t()}
  def run(%Session{} = session, ctx, opts) do
    effects = Keyword.fetch!(opts, :effects)
    log = Keyword.fetch!(opts, :log)
    cancelled? = Keyword.get(opts, :cancelled?, fn -> false end)

    Emit.plan(
      ctx.agent,
      session.id,
      Planner.entries(Session.steps(session), session.executed_prefix, session.executed_prefix)
    )

    step(session, session.executed_prefix, ctx, effects, log, cancelled?)
  end

  defp step(session, i, ctx, effects, log, cancelled?) do
    steps = Session.steps(session)

    cond do
      cancelled?.() ->
        {:cancelled, session}

      i >= length(steps) ->
        Emit.plan(ctx.agent, session.id, Planner.entries(steps, length(steps), nil))
        {:ok, session}

      true ->
        [action | args] = Enum.at(steps, i)
        exec = binding(session, action, args)
        id = "step-#{i}-#{session.replan_count}"
        call = tool_call(id, action, exec, ctx)
        Emit.plan(ctx.agent, session.id, Planner.entries(steps, session.executed_prefix, i))
        Emit.tool_call(ctx.agent, session.id, call)

        case permission(session, action, call, ctx, log) do
          {:go, session} ->
            Emit.tool_call_update(ctx.agent, session.id, %{
              "toolCallId" => id,
              "status" => "in_progress"
            })

            session =
              log.(
                session,
                Session.event(:agent_to_client, "acp/step", %{
                  "step" => i,
                  "action" => action,
                  "status" => "in_progress"
                })
              )

            case effect(exec, ctx, effects) do
              {:ok, content} ->
                Emit.tool_call_update(ctx.agent, session.id, %{
                  "toolCallId" => id,
                  "status" => "completed",
                  "content" => content
                })

                session =
                  log.(
                    session,
                    Session.event(:agent_to_client, "acp/step", %{
                      "step" => i,
                      "action" => action,
                      "status" => "completed"
                    })
                  )

                step(session, i + 1, ctx, effects, log, cancelled?)

              {:failed, reason, content} ->
                Emit.tool_call_update(ctx.agent, session.id, %{
                  "toolCallId" => id,
                  "status" => "failed",
                  "content" => content
                })

                session =
                  log.(
                    session,
                    Session.event(:agent_to_client, "acp/step", %{
                      "step" => i,
                      "action" => action,
                      "status" => "failed",
                      "reason" => reason
                    })
                  )

                replan(session, i, reason, ctx, effects, log, cancelled?)
            end

          {:rejected, session} ->
            Emit.tool_call_update(ctx.agent, session.id, %{
              "toolCallId" => id,
              "status" => "failed"
            })

            session =
              log.(
                session,
                Session.event(:agent_to_client, "acp/step", %{
                  "step" => i,
                  "action" => action,
                  "status" => "failed",
                  "reason" => "rejected"
                })
              )

            replan(session, i, "permission rejected", ctx, effects, log, cancelled?)

          {:refusal, session} ->
            Emit.tool_call_update(ctx.agent, session.id, %{
              "toolCallId" => id,
              "status" => "failed"
            })

            Emit.message(
              ctx.agent,
              session.id,
              "Stopped: #{action} was rejected for the rest of this session."
            )

            {:refusal, session}
        end
    end
  end

  defp permission(session, action, call, ctx, log) do
    if MapSet.member?(session.allow_always, action) do
      {:go, session}
    else
      case Agent.request_permission(ctx.agent, session.id, call, @permission_options) do
        {:ok, %{"outcome" => %{"outcome" => "selected", "optionId" => option}}} ->
          session =
            log.(
              session,
              Session.event(:client_to_agent, "acp/permission", %{
                "tool_call_id" => call["toolCallId"],
                "action" => action,
                "option_id" => option
              })
            )

          case option do
            "allow-once" -> {:go, session}
            "allow-always" -> {:go, session}
            "reject-once" -> {:rejected, session}
            _ -> {:refusal, session}
          end

        {:ok, _cancelled} ->
          {:refusal, session}

        {:error, reason} ->
          Emit.message(
            ctx.agent,
            session.id,
            "Permission request failed: #{inspect(reason)}"
          )

          {:refusal, session}
      end
    end
  end

  defp effect(%{kind: :terminal} = exec, ctx, effects) do
    case effects.run_command(ctx, exec.command, exec.args) do
      {:ok, %{exit_code: 0, output: out}} ->
        {:ok, [text_content(out)]}

      {:ok, %{exit_code: code, output: out}} ->
        {:failed, "exit #{code}", [text_content(out)]}

      {:error, {:unsupported_client_capability, cap}} ->
        {:failed, "client has no #{cap} capability", []}

      {:error, reason} ->
        {:failed, inspect(reason), []}
    end
  end

  defp effect(%{kind: :read} = exec, ctx, effects) do
    case effects.read_file(ctx, exec.path) do
      {:ok, content} ->
        {:ok, [text_content(content)]}

      {:error, {:unsupported_client_capability, cap}} ->
        {:failed, "client has no #{cap} capability", []}

      {:error, reason} ->
        {:failed, inspect(reason), []}
    end
  end

  defp effect(%{kind: :write} = exec, ctx, effects) do
    new_text = Map.get(exec, :content, "")

    case effects.write_file(ctx, exec.path, new_text) do
      {:ok, old} ->
        {:ok, [%{"type" => "diff", "path" => exec.path, "oldText" => old, "newText" => new_text}]}

      {:error, {:unsupported_client_capability, cap}} ->
        {:failed, "client has no #{cap} capability", []}

      {:error, reason} ->
        {:failed, inspect(reason), []}
    end
  end

  defp replan(session, i, reason, ctx, effects, log, cancelled?) do
    if session.replan_count >= @max_replans do
      Emit.message(
        ctx.agent,
        session.id,
        "Step #{i} failed (#{reason}) and the replan budget is spent."
      )

      {:ok, session}
    else
      case Planner.replan(session.domain, session.todo, session.plan, i) do
        {:ok, plan} ->
          count = session.replan_count + 1

          Emit.message(
            ctx.agent,
            session.id,
            "Step #{i} failed (#{reason}); replanned (#{count})."
          )

          session =
            log.(
              session,
              Session.event(:agent_to_client, "acp/plan", %{
                "plan" => plan,
                "completed_steps" => plan["completed_steps"] || i,
                "replan_count" => count
              })
            )

          step(session, session.executed_prefix, ctx, effects, log, cancelled?)

        {:error, why} ->
          Emit.message(ctx.agent, session.id, "Step #{i} failed (#{reason}); #{why}.")
          {:ok, session}
      end
    end
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

  defp tool_call(id, action, exec, ctx) do
    {kind, title, locations} =
      case exec.kind do
        :terminal ->
          {"execute", "#{action}: #{Enum.join([exec.command | exec.args], " ")}", []}

        :read ->
          {"read", "#{action}: #{exec.path}", [%{"path" => Path.join(ctx.cwd, exec.path)}]}

        :write ->
          {"edit", "#{action}: #{exec.path}", [%{"path" => Path.join(ctx.cwd, exec.path)}]}
      end

    %{
      "toolCallId" => id,
      "title" => title,
      "kind" => kind,
      "status" => "pending",
      "locations" => locations
    }
  end

  defp text_content(text),
    do: %{"type" => "content", "content" => %{"type" => "text", "text" => text}}
end
