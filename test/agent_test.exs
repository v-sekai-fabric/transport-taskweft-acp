# Copyright (c) 2026 K. S. Ernest (iFire) Lee
# SPDX-License-Identifier: MIT

defmodule TaskweftAcp.AgentTest do
  use ExUnit.Case, async: false

  alias ExMCP.ACP.Agent.Transport.Memory
  alias ExMCP.ACP.Client
  alias TaskweftAcp.Session.Store

  @cwd Path.expand(".")

  setup context do
    {:ok, store} = Store.start_link(name: nil, adapter: Store.Memory)
    {:ok, peer} = Memory.new_pair()

    {:ok, agent} =
      ExMCP.ACP.Agent.start_link(
        handler: TaskweftAcp.Agent,
        handler_opts: [store: store],
        agent_info: TaskweftAcp.agent_info(),
        transport: {:memory, peer}
      )

    {:ok, client} =
      Client.start_link(
        transport_mod: Memory,
        peer: peer,
        role: :client,
        handler: TaskweftAcp.FakeEditor,
        handler_opts:
          [test: self()] ++
            Map.get(context, :editor, permissions: ["allow-once"], commands: %{}),
        capabilities: %{
          "fs" => %{"readTextFile" => true, "writeTextFile" => true},
          "terminal" => true
        }
      )

    on_exit(fn ->
      try do
        GenServer.stop(agent)
      catch
        :exit, _ -> :ok
      end
    end)

    %{client: client, agent: agent, store: store}
  end

  test "session/new answers with an id and announces the commands", %{client: client} do
    assert {:ok, %{"sessionId" => sid}} = Client.new_session(client, @cwd)
    assert_receive {:update, ^sid, %{"sessionUpdate" => "available_commands_update"} = u}, 2_000
    assert Enum.any?(u["availableCommands"], &(&1["name"] == "run"))
  end

  test "/help ends the turn with the command list", %{client: client} do
    {:ok, %{"sessionId" => sid}} = Client.new_session(client, @cwd)
    assert {:ok, %{"stopReason" => "end_turn"}} = Client.prompt(client, sid, "/help")
    assert_receive {:update, ^sid, %{"sessionUpdate" => "agent_message_chunk"} = u}, 2_000
    assert u["content"]["text"] =~ "/run"
  end

  test "an unknown command is refused with the command list", %{client: client} do
    {:ok, %{"sessionId" => sid}} = Client.new_session(client, @cwd)
    assert {:ok, %{"stopReason" => "end_turn"}} = Client.prompt(client, sid, "/deploy")
    assert_receive {:update, ^sid, %{"sessionUpdate" => "agent_message_chunk"} = u}, 2_000
    assert u["content"]["text"] =~ "Unknown command /deploy"
  end

  test "/plan tests pass shows the two steps without running anything", %{client: client} do
    {:ok, %{"sessionId" => sid}} = Client.new_session(client, @cwd)
    assert {:ok, %{"stopReason" => "end_turn"}} = Client.prompt(client, sid, "/plan tests pass")
    assert_receive {:update, ^sid, %{"sessionUpdate" => "plan", "entries" => entries}}, 5_000
    assert Enum.map(entries, & &1["content"]) == ["run_build", "run_tests"]
    refute_received {:terminal, _}
  end

  test "/run tests pass executes both steps through the client with a permission each",
       %{client: client} do
    {:ok, %{"sessionId" => sid}} = Client.new_session(client, @cwd)
    assert {:ok, %{"stopReason" => "end_turn"}} = Client.prompt(client, sid, "/run tests pass")

    assert_receive {:permission, ^sid,
                    %{"title" => "run_build: mix compile --warnings-as-errors"}, "allow-once"},
                   5_000

    assert_receive {:terminal, "mix compile --warnings-as-errors"}, 5_000
    assert_receive {:permission, ^sid, %{"title" => "run_tests: mix test"}, "allow-once"}, 5_000
    assert_receive {:terminal, "mix test"}, 5_000

    assert_receive {:update, ^sid,
                    %{
                      "sessionUpdate" => "tool_call_update",
                      "toolCallId" => "step-1-0",
                      "status" => "completed"
                    }},
                   5_000

    assert {:ok, %{"stopReason" => "end_turn"}} = Client.prompt(client, sid, "/status")

    assert_receive {:update, ^sid,
                    %{"sessionUpdate" => "agent_message_chunk", "content" => %{"text" => status}}},
                   2_000

    assert status =~ "executed: 2 of 2"
  end

  @tag editor: [permissions: ["allow-once", "reject-once", "allow-once"], commands: %{}]
  test "a rejected step with no other decomposition ends the turn and keeps the prefix",
       %{client: client} do
    {:ok, %{"sessionId" => sid}} = Client.new_session(client, @cwd)
    assert {:ok, %{"stopReason" => "end_turn"}} = Client.prompt(client, sid, "/run tests pass")

    assert_receive {:update, ^sid,
                    %{
                      "sessionUpdate" => "tool_call_update",
                      "toolCallId" => "step-1-0",
                      "status" => "failed"
                    }},
                   5_000

    assert_receive {:update, ^sid,
                    %{"sessionUpdate" => "agent_message_chunk", "content" => %{"text" => text}}},
                   5_000

    assert text =~ "no recovery plan from step 1"
    assert {:ok, _} = Client.prompt(client, sid, "/status")

    assert_receive {:update, ^sid,
                    %{"sessionUpdate" => "agent_message_chunk", "content" => %{"text" => status}}},
                   2_000

    assert status =~ "executed: 1 of 2"
  end

  @alt """
  defmodule Alt do
    use Taskweft.DSL
    @name "alt"
    @variables %{done: %{type: :bool, init: %{job: false}}}
    @actions %{
      a_fast: %{params: [], body: [%{pointer_set: "/done/job", value: true}]},
      a_slow: %{params: [], body: [%{pointer_set: "/done/job", value: true}]}
    }
    @methods %{
      finish: %{
        params: [],
        alternatives: [
          %{name: :fast, subtasks: [["a_fast"]]},
          %{name: :slow, subtasks: [["a_slow"]]}
        ]
      }
    }
    @todo_list []
    @exec %{
      a_fast: %{kind: :terminal, command: "fast", args: []},
      a_slow: %{kind: :terminal, command: "slow", args: []}
    }
  end
  """

  @tag editor: [
         permissions: ["allow-once"],
         commands: %{"fast" => {1, "boom"}},
         files: %{Path.join(Path.expand("."), "alt.ex") => @alt}
       ]
  test "a failed step replans onto the other decomposition and the run completes",
       %{client: client} do
    {:ok, %{"sessionId" => sid}} = Client.new_session(client, @cwd)
    assert {:ok, %{"stopReason" => "end_turn"}} = Client.prompt(client, sid, "/domain alt.ex")
    assert {:ok, %{"stopReason" => "end_turn"}} = Client.prompt(client, sid, "/task finish")
    assert {:ok, %{"stopReason" => "end_turn"}} = Client.prompt(client, sid, "/run")
    assert_receive {:terminal, "fast"}, 5_000
    assert message_containing(sid, "replanned")
    assert_receive {:terminal, "slow"}, 5_000

    assert_receive {:update, ^sid,
                    %{
                      "sessionUpdate" => "tool_call_update",
                      "toolCallId" => "step-0-1",
                      "status" => "completed"
                    }},
                   5_000
  end

  @tag editor: [permissions: ["reject-always"], commands: %{}]
  test "reject-always stops the run with a refusal", %{client: client} do
    {:ok, %{"sessionId" => sid}} = Client.new_session(client, @cwd)
    assert {:ok, %{"stopReason" => "refusal"}} = Client.prompt(client, sid, "/run tests pass")
  end

  @tag editor: [permissions: ["allow-once"], commands: %{"mix test" => {1, "1 failure"}}]
  test "a failing command replans until the budget is spent, then ends the turn",
       %{client: client} do
    {:ok, %{"sessionId" => sid}} = Client.new_session(client, @cwd)
    assert {:ok, %{"stopReason" => "end_turn"}} = Client.prompt(client, sid, "/run tests pass")

    assert_receive {:update, ^sid,
                    %{"sessionUpdate" => "agent_message_chunk", "content" => %{"text" => text}}},
                   10_000

    assert text =~ "Step 1 failed (exit 1)"
  end

  test "session/list and session/load replay the transcript from the store", %{client: client} do
    {:ok, %{"sessionId" => sid}} = Client.new_session(client, @cwd)
    {:ok, _} = Client.prompt(client, sid, "/help")
    assert {:ok, %{"sessions" => sessions}} = Client.list_sessions(client)
    assert Enum.any?(sessions, &(&1["sessionId"] == sid))
    assert {:ok, _} = Client.load_session(client, sid, @cwd)

    assert_receive {:update, ^sid,
                    %{"sessionUpdate" => "user_message_chunk", "content" => %{"text" => "/help"}}},
                   2_000
  end

  test "/export writes the executed prefix as a script through the client's fs", %{client: client} do
    {:ok, %{"sessionId" => sid}} = Client.new_session(client, @cwd)
    {:ok, _} = Client.prompt(client, sid, "/run tests pass")

    assert_receive {:update, ^sid,
                    %{
                      "sessionUpdate" => "tool_call_update",
                      "toolCallId" => "step-1-0",
                      "status" => "completed"
                    }},
                   5_000

    assert {:ok, %{"stopReason" => "end_turn"}} = Client.prompt(client, sid, "/export")

    assert_receive {:update, ^sid,
                    %{
                      "sessionUpdate" => "tool_call_update",
                      "toolCallId" => "export-" <> _,
                      "content" => [%{"content" => %{"text" => script}}]
                    }},
                   5_000

    assert script =~ "SafeGDScript"
    assert script =~ ~s("args": ["compile", "--warnings-as-errors"])
    assert script =~ ~s("action": "run_tests")
    assert script =~ ~s("status": "completed")
  end

  # Agent messages arrive in order; skip the earlier ones until the wanted text appears.
  defp message_containing(sid, text, timeout \\ 5_000) do
    receive do
      {:update, ^sid, %{"sessionUpdate" => "agent_message_chunk", "content" => %{"text" => t}}} ->
        if String.contains?(t, text), do: true, else: message_containing(sid, text, timeout)

      {:update, ^sid, _other} ->
        message_containing(sid, text, timeout)
    after
      timeout -> false
    end
  end
end
