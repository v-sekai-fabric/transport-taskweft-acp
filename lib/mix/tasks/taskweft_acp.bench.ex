# Copyright (c) 2026 K. S. Ernest (iFire) Lee
# SPDX-License-Identifier: MIT

defmodule Mix.Tasks.TaskweftAcp.Bench do
  @shortdoc "Per-step latency of a ten-step run: the floor, then each store mode"
  @moduledoc """
      mix taskweft_acp.bench [--runs N]

  Drives a ten-step plan through the agent over the memory transport with a scripted
  editor that answers instantly, so the number is the agent's own cost per step. The
  floor is the memory store; plain mode adds the helper and one SQLite transaction
  per event; fabric mode (when the cluster is reachable) adds one FoundationDB commit.
  A row without the floor beside it is not a measurement, so the floor always prints.
  """
  use Mix.Task

  alias ExMCP.ACP.Agent.Transport.Memory
  alias ExMCP.ACP.Client
  alias TaskweftAcp.Session.Store

  @domain """
  defmodule Bench do
    use Taskweft.DSL
    @name "bench"
    @variables %{ticked: %{type: :bool, init: %{repo: false}}}
    @actions %{tick: %{params: [], body: [%{pointer_set: "/ticked/repo", value: true}]}}
    @methods %{
      ten: %{
        params: [],
        alternatives: [
          %{
            name: :all,
            subtasks: [
              ["tick"], ["tick"], ["tick"], ["tick"], ["tick"],
              ["tick"], ["tick"], ["tick"], ["tick"], ["tick"]
            ]
          }
        ]
      }
    }
    @todo_list []
    @exec %{tick: %{kind: :terminal, command: "tick", args: []}}
  end
  """

  @impl true
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [runs: :integer])
    runs = opts[:runs] || 5
    Mix.Task.run("app.start")
    fabric? = System.get_env("WEFT_FDB_CLUSTER_FILE") not in [nil, ""]

    modes =
      [
        {"floor (memory store)", Store.Memory, []},
        {"plain (helper + SQLite)", Store.Vfs, [mode: :plain]}
      ] ++ if(fabric?, do: [{"fabric (weft_fdb)", Store.Vfs, [mode: :fabric]}], else: [])

    Mix.shell().info(
      String.pad_trailing("mode", 26) <>
        "  p50 ms/step  p95 ms/step  (#{runs} runs of 10 steps)"
    )

    for {label, adapter, adapter_opts} <- modes do
      per_step =
        1..runs |> Enum.flat_map(fn _ -> one_run(adapter, adapter_opts) end) |> Enum.sort()

      Mix.shell().info(
        String.pad_trailing(label, 26) <> pad(pct(per_step, 0.5)) <> pad(pct(per_step, 0.95))
      )
    end

    if not fabric?, do: Mix.shell().info("fabric: not run, WEFT_FDB_CLUSTER_FILE is unset")
  end

  # One run: session/new, load the bench domain, run it; returns per-step wall times.
  defp one_run(adapter, adapter_opts) do
    dir = Path.join(System.tmp_dir!(), "taskweft_acp_bench_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, "bench.ex")

    {:ok, store} =
      Store.start_link(name: nil, adapter: adapter, adapter_opts: [dir: dir] ++ adapter_opts)

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
        handler: TaskweftAcp.BenchEditor,
        handler_opts: [test: self(), files: %{"bench.ex" => @domain}],
        event_listener: self(),
        capabilities: %{
          "fs" => %{"readTextFile" => true, "writeTextFile" => true},
          "terminal" => true
        }
      )

    {:ok, %{"sessionId" => sid}} = Client.new_session(client, dir)
    {:ok, _} = Client.prompt(client, sid, "/domain #{path}")
    {:ok, _} = Client.prompt(client, sid, "/task ten")
    t0 = System.monotonic_time(:microsecond)
    {:ok, _} = Client.prompt(client, sid, "/run")
    total = System.monotonic_time(:microsecond) - t0
    stamps = collect_stamps([])
    GenServer.stop(client)
    GenServer.stop(agent)
    GenServer.stop(store)
    _ = File.rm_rf!(dir)

    if length(stamps) < 9,
      do: Mix.raise("bench: #{length(stamps) + 1} of 10 steps completed in #{total / 1000} ms")

    stamps
  end

  # Completed tool_call_update timestamps, differenced into per-step milliseconds.
  defp collect_stamps(acc) do
    receive do
      {:step_done, at} -> collect_stamps([at | acc])
    after
      0 ->
        acc
        |> Enum.reverse()
        |> Enum.chunk_every(2, 1, :discard)
        |> Enum.map(fn [a, b] -> (b - a) / 1000 end)
    end
  end

  defp pct([], _), do: 0.0

  defp pct(sorted, p) do
    i = min(length(sorted) - 1, round(p * (length(sorted) - 1)))
    Enum.at(sorted, i)
  end

  defp pad(ms), do: String.pad_leading(:erlang.float_to_binary(ms * 1.0, decimals: 2), 13)
end

defmodule TaskweftAcp.BenchEditor do
  @moduledoc false
  @behaviour ExMCP.ACP.Client.Handler

  @impl true
  def init(opts),
    do: {:ok, %{test: Keyword.fetch!(opts, :test), files: Keyword.get(opts, :files, %{}), n: 1}}

  @impl true
  def handle_session_update(
        _sid,
        %{"sessionUpdate" => "tool_call_update", "status" => "completed"},
        state
      ) do
    send(state.test, {:step_done, System.monotonic_time(:microsecond)})
    {:ok, state}
  end

  def handle_session_update(_sid, _update, state), do: {:ok, state}

  @impl true
  def handle_permission_request(_sid, _tool_call, _options, state),
    do: {:ok, %{"outcome" => "selected", "optionId" => "allow-always"}, state}

  @impl true
  def handle_file_read(_sid, path, _opts, state) do
    case Map.fetch(state.files, Path.basename(path)) do
      {:ok, content} -> {:ok, content, state}
      :error -> {:error, "no such file #{path}", state}
    end
  end

  @impl true
  def handle_file_write(_sid, _path, _content, state), do: {:ok, state}

  @impl true
  def handle_terminal_request("terminal/create", _params, _id, state),
    do: {:ok, %{"terminalId" => "t#{state.n}"}, %{state | n: state.n + 1}}

  def handle_terminal_request("terminal/output", _params, _id, state),
    do: {:ok, %{"output" => "", "truncated" => false}, state}

  def handle_terminal_request("terminal/wait_for_exit", _params, _id, state),
    do: {:ok, %{"exitCode" => 0}, state}

  def handle_terminal_request(_method, _params, _id, state), do: {:ok, %{}, state}

  @impl true
  def terminate(_reason, _state), do: :ok
end
