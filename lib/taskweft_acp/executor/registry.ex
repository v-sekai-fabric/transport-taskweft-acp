# Copyright (c) 2026 K. S. Ernest (iFire) Lee
# SPDX-License-Identifier: MIT

defmodule TaskweftAcp.Executor.Registry do
  @moduledoc """
  Which executors are connected right now, by name, with their labels and the agent
  process that owns their session. Connection state lives here; the store keeps the
  registry rows that outlive a connection.
  """

  use GenServer

  defstruct executors: %{}, bindings: %{}

  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc "Bind a session to a connected executor by name."
  @spec bind(GenServer.server(), String.t(), String.t()) :: :ok | {:error, :not_connected}
  def bind(registry \\ __MODULE__, session_id, name),
    do: GenServer.call(registry, {:bind, session_id, name})

  @doc "The connected executor process bound to a session, if any."
  @spec executor_for(GenServer.server(), String.t()) :: {:ok, pid()} | :error
  def executor_for(registry \\ __MODULE__, session_id) do
    GenServer.call(registry, {:executor_for, session_id})
  catch
    :exit, _ -> :error
  end

  @spec register(GenServer.server(), String.t(), [String.t()], pid()) :: :ok
  def register(registry \\ __MODULE__, name, labels, pid),
    do: GenServer.call(registry, {:register, name, labels, pid})

  @spec lookup(GenServer.server(), String.t()) :: {:ok, map()} | :error
  def lookup(registry \\ __MODULE__, name), do: GenServer.call(registry, {:lookup, name})

  @spec by_label(GenServer.server(), String.t()) :: [map()]
  def by_label(registry \\ __MODULE__, label), do: GenServer.call(registry, {:by_label, label})

  @spec all(GenServer.server()) :: [map()]
  def all(registry \\ __MODULE__), do: GenServer.call(registry, :all)

  @impl true
  def init(_opts), do: {:ok, %__MODULE__{}}

  @impl true
  def handle_call({:register, name, labels, pid}, _from, s) do
    _ = Process.monitor(pid)

    entry = %{
      name: name,
      labels: labels,
      pid: pid,
      connected_at: TaskweftAcp.Session.now()
    }

    {:reply, :ok, %{s | executors: Map.put(s.executors, name, entry)}}
  end

  def handle_call({:lookup, name}, _from, s), do: {:reply, Map.fetch(s.executors, name), s}

  def handle_call({:by_label, label}, _from, s) do
    {:reply, s.executors |> Map.values() |> Enum.filter(&(label in &1.labels)), s}
  end

  def handle_call(:all, _from, s), do: {:reply, Map.values(s.executors), s}

  def handle_call({:bind, session_id, name}, _from, s) do
    if Map.has_key?(s.executors, name),
      do: {:reply, :ok, %{s | bindings: Map.put(s.bindings, session_id, name)}},
      else: {:reply, {:error, :not_connected}, s}
  end

  def handle_call({:executor_for, session_id}, _from, s) do
    with {:ok, name} <- Map.fetch(s.bindings, session_id),
         {:ok, %{pid: pid}} <- Map.fetch(s.executors, name) do
      {:reply, {:ok, pid}, s}
    else
      _ -> {:reply, :error, s}
    end
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, s) do
    executors = s.executors |> Enum.reject(fn {_, e} -> e.pid == pid end) |> Map.new()
    {:noreply, %{s | executors: executors}}
  end

  def handle_info(_other, s), do: {:noreply, s}
end
