# Copyright (c) 2026 K. S. Ernest (iFire) Lee
# SPDX-License-Identifier: MIT

defmodule TaskweftAcp.Bridge.McpServer do
  @moduledoc """
  The MCP tools Claude Code calls. Each is an ACP session verb on the bridge; the
  prompt tool returns the run's transcript so the chat keeps the context.
  """

  use ExMCP.Server.Handler
  use ExMCP.Server.DSL, name: "taskweft-acp"

  alias TaskweftAcp.Bridge

  tool "acp_sessions", "The ACP sessions the store knows, newest first." do
    handle(fn _args, _state ->
      case Bridge.sessions() do
        {:ok, sessions} -> {:ok, json(sessions)}
        {:error, reason} -> {:ok, error(inspect(reason))}
      end
    end)
  end

  tool "acp_new_session", "Open an ACP session on a directory; returns its id." do
    param(:cwd, :string, required: true, description: "The working directory the plan acts on.")

    param(:executor, :string,
      description: "The connected executor that runs the steps (omit for this machine)."
    )

    handle(fn args, _state ->
      case Bridge.new_session(Bridge, args["cwd"], executor: args["executor"]) do
        {:ok, id} -> {:ok, json(%{session_id: id, cwd: args["cwd"], executor: args["executor"]})}
        {:error, reason} -> {:ok, error(inspect(reason))}
      end
    end)
  end

  tool "acp_load_session", "Load an existing session by id, replaying its transcript." do
    param(:session_id, :string, required: true)
    param(:cwd, :string, required: true)

    handle(fn args, _state ->
      case Bridge.load_session(args["session_id"], args["cwd"]) do
        :ok -> {:ok, json(%{loaded: args["session_id"]})}
        {:error, reason} -> {:ok, error(inspect(reason))}
      end
    end)
  end

  tool "acp_prompt",
       "Send one prompt to a session (a slash command or plain text such as \"run the tests\") and return the run: messages, plan entries, each step's status and the permissions recorded." do
    param(:session_id, :string, required: true)
    param(:text, :string, required: true, description: "/help lists the commands.")

    handle(fn args, _state ->
      case Bridge.prompt(args["session_id"], args["text"]) do
        {:ok, %{stop_reason: reason, transcript: lines}} ->
          {:ok, text(render(reason, lines))}

        {:error, reason} ->
          {:ok, error(inspect(reason))}
      end
    end)
  end

  tool "acp_cancel", "Cancel the session's running prompt between steps." do
    param(:session_id, :string, required: true)

    handle(fn args, _state ->
      :ok = Bridge.cancel(args["session_id"])
      {:ok, json(%{cancelled: args["session_id"]})}
    end)
  end

  tool "acp_close", "Close a session; its log stays in the store." do
    param(:session_id, :string, required: true)

    handle(fn args, _state ->
      case Bridge.close(args["session_id"]) do
        :ok -> {:ok, json(%{closed: args["session_id"]})}
        {:error, reason} -> {:ok, error(inspect(reason))}
      end
    end)
  end

  @doc false
  def render(stop_reason, lines) do
    body =
      Enum.map_join(lines, "\n", fn
        %{"sessionUpdate" => "agent_message_chunk", "content" => %{"text" => t}} ->
          t

        %{"sessionUpdate" => "agent_thought_chunk", "content" => %{"text" => t}} ->
          "(thinking) " <> t

        %{"sessionUpdate" => "plan", "entries" => entries} ->
          "plan:\n" <> Enum.map_join(entries, "\n", &"  [#{&1["status"]}] #{&1["content"]}")

        %{"sessionUpdate" => "tool_call", "title" => title, "toolCallId" => id} ->
          "step #{id}: #{title}"

        %{"sessionUpdate" => "tool_call_update", "toolCallId" => id, "status" => status} = u ->
          out =
            u
            |> Map.get("content", [])
            |> Enum.map_join("", fn
              %{"type" => "content", "content" => %{"text" => t}} -> "\n" <> indent(t)
              %{"type" => "diff", "path" => p} -> "\n  diff #{p}"
              _ -> ""
            end)

          "step #{id}: #{status}#{out}"

        %{"permission" => action, "optionId" => answer} ->
          "permission #{action}: #{answer}"

        _ ->
          ""
      end)
      |> String.split("\n")
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n")

    "stop: #{stop_reason}\n" <> body
  end

  defp indent(text) do
    text |> String.trim_trailing() |> String.split("\n") |> Enum.map_join("\n", &("  " <> &1))
  end

  defp text(s), do: %{content: [%{type: "text", text: s}]}
  defp json(term), do: text(Jason.encode!(term, pretty: true))
  defp error(msg), do: %{content: [%{type: "text", text: msg}], isError: true}
end
