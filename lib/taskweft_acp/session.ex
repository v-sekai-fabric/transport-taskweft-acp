# Copyright (c) 2026 K. S. Ernest (iFire) Lee
# SPDX-License-Identifier: MIT

defmodule TaskweftAcp.Session do
  @moduledoc """
  One ACP session as derived state. The store holds the event log; this struct is what
  replaying that log yields, and every change to it is an event appended first.
  """

  alias TaskweftAcp.Domain

  defstruct id: nil,
            cwd: nil,
            created_at: nil,
            domain: nil,
            goals: [],
            todo: [],
            plan: nil,
            executed_prefix: 0,
            step_status: %{},
            replan_count: 0,
            allow_always: MapSet.new(),
            permissions: [],
            transcript: [],
            prompt_ordinal: 0,
            open_prompt: nil,
            executor: nil,
            fallback: false

  @type t :: %__MODULE__{}

  @spec new(String.t(), String.t()) :: t()
  def new(id, cwd), do: %__MODULE__{id: id, cwd: cwd, created_at: now()}

  def now, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  def new_id, do: "acp_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

  @doc "An event as the store keeps it; `direction` is client_to_agent or agent_to_client."
  def event(direction, method, payload) when direction in [:client_to_agent, :agent_to_client] do
    %{
      "direction" => Atom.to_string(direction),
      "method" => method,
      "payload" => payload,
      "at" => now()
    }
  end

  @spec from_events(String.t(), [map()]) :: t()
  def from_events(id, events) do
    Enum.reduce(events, %__MODULE__{id: id}, &apply_event(&2, &1))
  end

  @doc "Pure transition: the session after one logged event."
  @spec apply_event(t(), map()) :: t()
  def apply_event(s, %{"method" => "session/new", "payload" => p}) do
    %{s | cwd: p["cwd"], created_at: p["at"] || s.created_at}
  end

  def apply_event(s, %{"method" => "acp/domain", "payload" => p}) do
    case Domain.load(p["source"], p["path"]) do
      {:ok, domain} -> %{s | domain: domain, plan: nil, executed_prefix: 0}
      {:error, _} -> s
    end
  end

  def apply_event(s, %{"method" => "acp/goals", "payload" => p}) do
    %{s | goals: Enum.map(p["goals"], fn [k, v] -> {k, v} end)}
  end

  def apply_event(s, %{"method" => "acp/todo", "payload" => p}), do: %{s | todo: p["todo"]}

  def apply_event(s, %{"method" => "acp/plan", "payload" => p}) do
    %{
      s
      | plan: p["plan"],
        executed_prefix: p["completed_steps"] || 0,
        replan_count: p["replan_count"] || s.replan_count
    }
  end

  def apply_event(s, %{"method" => "acp/step", "payload" => p}) do
    status = if p["reason"], do: "failed (#{p["reason"]})", else: p["status"]
    s = %{s | step_status: Map.put(s.step_status, p["step"], status)}

    if p["status"] == "completed",
      do: %{s | executed_prefix: max(s.executed_prefix, p["step"] + 1)},
      else: s
  end

  def apply_event(s, %{"method" => "acp/permission", "payload" => p}) do
    allow =
      if p["option_id"] == "allow-always",
        do: MapSet.put(s.allow_always, p["action"]),
        else: s.allow_always

    %{s | allow_always: allow, permissions: s.permissions ++ [p]}
  end

  def apply_event(s, %{"method" => "acp/executor", "payload" => p}),
    do: %{s | executor: p["name"]}

  def apply_event(s, %{"method" => "acp/fallback", "payload" => p}),
    do: %{s | fallback: p["active"]}

  def apply_event(s, %{"method" => "session/prompt", "payload" => p}) do
    text = prompt_text(p["prompt"] || [])
    ordinal = s.prompt_ordinal + 1

    %{
      s
      | prompt_ordinal: ordinal,
        open_prompt: ordinal,
        transcript: s.transcript ++ [%{"role" => "user", "text" => text, "prompt" => ordinal}]
    }
  end

  def apply_event(s, %{"method" => "acp/stop", "payload" => p}) do
    line = %{"role" => "stop", "text" => p["stopReason"], "prompt" => s.prompt_ordinal}
    %{s | open_prompt: nil, transcript: s.transcript ++ [line]}
  end

  def apply_event(s, %{"method" => "session/update", "payload" => %{"sessionUpdate" => kind} = u}) do
    case kind do
      "agent_message_chunk" -> add(s, "agent", get_in(u, ["content", "text"]))
      "agent_thought_chunk" -> add(s, "thought", get_in(u, ["content", "text"]))
      "tool_call" -> add(s, "tool", u["title"], u["toolCallId"], u["status"])
      "tool_call_update" -> add(s, "tool", nil, u["toolCallId"], u["status"])
      _ -> s
    end
  end

  def apply_event(s, _other), do: s

  @doc "The text blocks of an ACP prompt, joined."
  def prompt_text(blocks) do
    blocks
    |> Enum.filter(&(&1["type"] == "text"))
    |> Enum.map_join("\n", & &1["text"])
    |> String.trim()
  end

  def steps(%__MODULE__{plan: nil}), do: []
  def steps(%__MODULE__{plan: plan}), do: plan["plan"] || []

  defp add(s, role, text, id \\ nil, status \\ nil)
  defp add(s, _role, nil, _id, nil), do: s

  defp add(s, role, text, id, status) do
    line =
      %{"role" => role, "prompt" => s.prompt_ordinal}
      |> put_if("text", text)
      |> put_if("tool_call_id", id)
      |> put_if("status", status)

    %{s | transcript: s.transcript ++ [line]}
  end

  defp put_if(map, _k, nil), do: map
  defp put_if(map, k, v), do: Map.put(map, k, v)
end
