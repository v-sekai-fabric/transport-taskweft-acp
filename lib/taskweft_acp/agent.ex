# Copyright (c) 2026 K. S. Ernest (iFire) Lee
# SPDX-License-Identifier: MIT

defmodule TaskweftAcp.Agent do
  @moduledoc """
  The ACP agent handler. Every request and every update is appended to the session's
  event log before the agent acts on it; the in-memory session is what replaying that
  log yields, so `session/load` and `session/list` read the store, not this process.
  """

  @behaviour ExMCP.ACP.Agent.Handler

  alias ExMCP.ACP.Agent, as: Acp
  alias TaskweftAcp.{Domain, Emit, Grammar, Planner, Run, Session}
  alias TaskweftAcp.Session.Store

  @cancel_table :taskweft_acp_cancel

  # Sessions live in a public ETS table because the executor runs in its own Task and hands
  # the finished session back through it.
  defstruct sessions: nil, store: Store, effects: TaskweftAcp.Effects.Acp, executor: nil

  @impl true
  def init(opts) do
    _ =
      if :ets.whereis(@cancel_table) == :undefined,
        do: :ets.new(@cancel_table, [:named_table, :public, :set])

    {:ok,
     %__MODULE__{
       sessions: :ets.new(:taskweft_acp_sessions, [:public, :set]),
       store: Keyword.get(opts, :store, Store),
       effects: Keyword.get(opts, :effects, TaskweftAcp.Effects.Acp),
       executor: Keyword.get(opts, :executor)
     }}
  end

  @impl true
  def handle_new_session(params, ctx, st) do
    cwd = params["cwd"] || File.cwd!()
    id = Session.new_id()

    with :ok <- Store.create_session(st.store, id, %{"cwd" => cwd}),
         {:ok, domain} <- Domain.builtin() do
      domain = %{domain | exec: Domain.apply_overlay(domain.exec, cwd)}
      session = Session.new(id, cwd)

      session =
        session
        |> log(
          st,
          Session.event(
            :client_to_agent,
            "session/new",
            Map.put(params, "at", session.created_at)
          )
        )
        |> log(
          st,
          Session.event(:agent_to_client, "acp/domain", %{
            "source" => domain.source,
            "path" => domain.path
          })
        )

      session = %{session | domain: domain}
      announce(ctx.agent, session)
      {:reply, %{"sessionId" => id}, put(st, session)}
    else
      {:error, reason} -> {:error, "cannot open a session: #{inspect(reason)}", st}
    end
  end

  @impl true
  def handle_load_session(%{"sessionId" => id} = params, ctx, st) do
    case load(st, id) do
      {:ok, session} ->
        replay(ctx.agent, session)
        announce(ctx.agent, session)
        {:reply, %{}, put(st, session)}

      {:error, reason} ->
        {:error, "no session #{id}: #{inspect(reason)}", st}
    end
    |> tap(fn _ -> params end)
  end

  @impl true
  def handle_resume_session(%{"sessionId" => id}, ctx, st) do
    case load(st, id) do
      {:ok, session} ->
        announce(ctx.agent, session)
        {:reply, %{}, put(st, session)}

      {:error, reason} ->
        {:error, "no session #{id}: #{inspect(reason)}", st}
    end
  end

  @impl true
  def handle_list_sessions(params, _ctx, st) do
    cwd = params["cwd"] || :all

    case Store.sessions(st.store, cwd) do
      {:ok, rows} ->
        sessions =
          for row <- rows do
            %{
              "sessionId" => row["id"],
              "cwd" => row["cwd"],
              "title" => "taskweft",
              "updatedAt" => row["created_at"]
            }
          end

        {:reply, %{"sessions" => sessions}, st}

      {:error, reason} ->
        {:error, "store: #{inspect(reason)}", st}
    end
  end

  @impl true
  def handle_close_session(id, _ctx, st) when is_binary(id) do
    :ets.delete(st.sessions, id)
    {:reply, %{}, st}
  end

  @impl true
  def handle_cancel(session_id, _ctx, st) do
    :ets.insert(@cancel_table, {session_id, true})
    {:noreply, st}
  end

  @impl true
  def handle_prompt(session_id, prompt, ctx, st) do
    case fetch(st, session_id) do
      :error ->
        {:error, "unknown session #{session_id}", st}

      {:ok, session} ->
        session =
          log(
            session,
            st,
            Session.event(:client_to_agent, "session/prompt", %{"prompt" => prompt})
          )

        text = Session.prompt_text(prompt)
        :ets.delete(@cancel_table, session_id)

        case Grammar.parse(text) do
          {:error, {:unknown_command, cmd}} ->
            say(ctx.agent, session, "Unknown command #{cmd}.\n" <> Grammar.help_text())
            finish(st, session, ctx, "end_turn")

          {:ok, intent} ->
            dispatch(intent, session, ctx, st)
        end
    end
  end

  defp dispatch(%{kind: :help}, session, ctx, st) do
    say(
      ctx.agent,
      session,
      "This agent plans with taskweft and runs each step with your permission.\n" <>
        Grammar.help_text()
    )

    finish(st, session, ctx, "end_turn")
  end

  defp dispatch(%{kind: :status}, session, ctx, st) do
    say(ctx.agent, session, status_text(session))
    finish(st, session, ctx, "end_turn")
  end

  defp dispatch(%{kind: :explain}, session, ctx, st) do
    text =
      case session.plan do
        nil -> "No plan yet. /plan or /run first."
        plan -> "Explain tree:\n" <> Jason.encode!(plan["explain"] || %{}, pretty: true)
      end

    say(ctx.agent, session, text)
    finish(st, session, ctx, "end_turn")
  end

  defp dispatch(%{kind: :export}, session, ctx, st) do
    script = TaskweftAcp.Export.script(session)
    path = Path.join(TaskweftAcp.workspace_dir(session.cwd), "#{session.id}.sh")
    ectx = %{agent: ctx.agent, session_id: session.id, cwd: session.cwd}
    id = "export-#{session.prompt_ordinal}"

    Emit.tool_call(ctx.agent, session.id, %{
      "toolCallId" => id,
      "title" => "export: #{path}",
      "kind" => "edit",
      "status" => "in_progress",
      "locations" => [%{"path" => path}]
    })

    status =
      case st.effects.write_file(ectx, path, script) do
        {:ok, _} -> "completed"
        {:error, _} -> "failed"
      end

    Emit.tool_call_update(ctx.agent, session.id, %{
      "toolCallId" => id,
      "status" => status,
      "content" => [%{"type" => "content", "content" => %{"type" => "text", "text" => script}}]
    })

    say(ctx.agent, session, "Exported #{session.executed_prefix} executed step(s) to #{path}.")
    finish(st, session, ctx, "end_turn")
  end

  defp dispatch(%{kind: :domain, path: path}, session, ctx, st) do
    ectx = %{agent: ctx.agent, session_id: session.id, cwd: session.cwd}

    with {:ok, source} <- st.effects.read_file(ectx, path),
         {:ok, domain} <- Domain.load(source, path) do
      domain = %{domain | exec: Domain.apply_overlay(domain.exec, session.cwd)}

      session =
        log(
          session,
          st,
          Session.event(:agent_to_client, "acp/domain", %{"source" => source, "path" => path})
        )

      session = %{session | domain: domain, plan: nil, executed_prefix: 0}

      say(
        ctx.agent,
        session,
        "Domain loaded from #{path}: #{map_size(domain.exec)} bound actions."
      )

      finish(st, session, ctx, "end_turn")
    else
      {:error, reason} ->
        say(ctx.agent, session, "Could not load #{path}: #{format(reason)}")
        finish(st, session, ctx, "end_turn")
    end
  end

  defp dispatch(%{kind: :goal, goals: goals}, session, ctx, st) do
    session =
      log(
        session,
        st,
        Session.event(:client_to_agent, "acp/goals", %{
          "goals" => Enum.map(goals, &Tuple.to_list/1)
        })
      )

    todo = for {name, true} <- goals, do: [name]

    session =
      log(
        %{session | goals: goals},
        st,
        Session.event(:client_to_agent, "acp/todo", %{"todo" => todo})
      )

    say(ctx.agent, session, "Goals: #{inspect(goals)}; todo: #{inspect(todo)}. /plan or /run.")
    finish(st, %{session | todo: todo}, ctx, "end_turn")
  end

  defp dispatch(%{kind: :task, todo: todo}, session, ctx, st) do
    todo = session.todo ++ todo
    session = log(session, st, Session.event(:client_to_agent, "acp/todo", %{"todo" => todo}))
    say(ctx.agent, session, "Todo: #{inspect(todo)}.")
    finish(st, %{session | todo: todo}, ctx, "end_turn")
  end

  defp dispatch(%{kind: :plan, todo: todo}, session, ctx, st) do
    session = with_todo(session, todo, st)

    case make_plan(session, ctx, st) do
      {:ok, session} ->
        steps = Session.steps(session)
        Emit.plan(ctx.agent, session.id, Planner.entries(steps, 0, nil))

        say(
          ctx.agent,
          session,
          "Plan (#{length(steps)} steps):\n" <>
            Enum.map_join(steps, "\n", &("- " <> Enum.join(&1, " "))) <> "\n/run executes it."
        )

        finish(st, session, ctx, "end_turn")

      {:error, session, reason} ->
        say(ctx.agent, session, reason)
        finish(st, session, ctx, "end_turn")
    end
  end

  defp dispatch(%{kind: :run, todo: todo}, session, ctx, st) do
    session = with_todo(session, todo, st)
    execute(session, ctx, st, fn s -> if s.plan, do: {:ok, s}, else: make_plan(s, ctx, st) end)
  end

  defp dispatch(%{kind: :replan}, session, ctx, st) do
    execute(session, ctx, st, fn s ->
      if s.plan, do: {:ok, s}, else: {:error, s, "Nothing to replan; /plan or /run first."}
    end)
  end

  defp execute(session, ctx, st, prepare) do
    case prepare.(session) do
      {:error, session, reason} ->
        say(ctx.agent, session, reason)
        finish(st, session, ctx, "end_turn")

      {:ok, session} ->
        handler = self()
        store = st.store
        effects = st.effects
        ectx = %{agent: ctx.agent, session_id: session.id, cwd: session.cwd}
        log = fn s, event -> log(s, %{st | store: store}, event) end
        cancelled? = fn -> :ets.member(@cancel_table, session.id) end

        table = st.sessions

        {:ok, _} =
          Task.start(fn ->
            Emit.thought(
              ctx.agent,
              session.id,
              "executing #{length(Session.steps(session))} steps"
            )

            {outcome, session} =
              try do
                Run.run(session, ectx, effects: effects, log: log, cancelled?: cancelled?)
              rescue
                e ->
                  Emit.message(ctx.agent, session.id, "The run stopped: " <> Exception.message(e))
                  {:ok, session}
              end

            reason =
              case outcome do
                :ok -> "end_turn"
                :cancelled -> "cancelled"
                :refusal -> "refusal"
              end

            session =
              log.(
                session,
                Session.event(:agent_to_client, "acp/stop", %{"stopReason" => reason})
              )

            :ets.insert(table, {session.id, session})
            Acp.finish_prompt(ctx.agent, ctx.prompt_id, reason)
          end)

        {:noreply, put(st, session)}
        |> tap(fn _ -> handler end)
    end
  end

  defp make_plan(session, ctx, st) do
    cond do
      session.domain == nil ->
        {:error, session, "No domain loaded."}

      session.todo == [] ->
        {:error, session,
         "Nothing to plan: /goal tests_pass=true, /task <name>, or plain text such as \"run the tests\"."}

      true ->
        Emit.thought(ctx.agent, session.id, "planning #{inspect(session.todo)}")

        case Planner.plan(session.domain, session.todo) do
          {:ok, plan} ->
            session =
              log(
                session,
                st,
                Session.event(:agent_to_client, "acp/plan", %{
                  "plan" => plan,
                  "completed_steps" => 0,
                  "replan_count" => 0
                })
              )

            {:ok, %{session | plan: plan, executed_prefix: 0, replan_count: 0}}

          {:error, reason} ->
            {:error, session, reason}
        end
    end
  end

  defp with_todo(session, [], _st), do: session

  defp with_todo(session, todo, st) do
    session = log(session, st, Session.event(:client_to_agent, "acp/todo", %{"todo" => todo}))
    %{session | todo: todo, plan: nil, executed_prefix: 0, replan_count: 0}
  end

  defp finish(st, session, ctx, reason) do
    session =
      log(session, st, Session.event(:agent_to_client, "acp/stop", %{"stopReason" => reason}))

    {:reply, %{"stopReason" => reason}, put(st, session)}
    |> tap(fn _ -> ctx end)
  end

  defp say(agent, session, text) do
    Emit.message(agent, session.id, text)
  end

  defp announce(agent, session) do
    Emit.available_commands(agent, session.id, Grammar.available_commands())

    Emit.session_info(agent, session.id, %{
      "title" => "taskweft #{session.id}",
      "updatedAt" => Session.now()
    })
  end

  defp replay(agent, session) do
    Enum.each(session.transcript, fn line ->
      case line["role"] do
        "user" ->
          Emit.update(agent, session.id, %{
            "sessionUpdate" => "user_message_chunk",
            "content" => %{"type" => "text", "text" => line["text"]}
          })

        "agent" ->
          Emit.message(agent, session.id, line["text"])

        _ ->
          :ok
      end
    end)
  end

  defp status_text(session) do
    """
    session #{session.id} in #{session.cwd}
    domain: #{(session.domain && (session.domain.path || "built-in repo_chores")) || "none"}
    goals: #{inspect(session.goals)}
    todo: #{inspect(session.todo)}
    plan: #{inspect(Session.steps(session))}
    executed: #{session.executed_prefix} of #{length(Session.steps(session))}, replans #{session.replan_count}
    always allowed: #{inspect(MapSet.to_list(session.allow_always))}
    executor: #{session.executor || "the client"}
    """
  end

  defp log(session, st, event) do
    case Store.append(st.store, session.id, event) do
      {:ok, _ordinal} -> Session.apply_event(session, event)
      {:error, reason} -> raise "store append failed: #{inspect(reason)}"
    end
  end

  defp load(st, id) do
    with {:ok, events} <- Store.events(st.store, id, 0),
         false <- events == [] do
      session = Session.from_events(id, events)

      domain =
        session.domain &&
          %{session.domain | exec: Domain.apply_overlay(session.domain.exec, session.cwd)}

      {:ok, %{session | domain: domain}}
    else
      true -> {:error, :not_found}
      {:error, _} = e -> e
    end
  end

  defp put(st, session) do
    :ets.insert(st.sessions, {session.id, session})
    st
  end

  defp fetch(st, id) do
    case :ets.lookup(st.sessions, id) do
      [{^id, session}] -> {:ok, session}
      [] -> :error
    end
  end

  defp format(reason) when is_binary(reason), do: reason
  defp format(reason), do: inspect(reason)
end
