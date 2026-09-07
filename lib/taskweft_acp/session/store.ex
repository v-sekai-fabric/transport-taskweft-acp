# Copyright (c) 2026 K. S. Ernest (iFire) Lee
# SPDX-License-Identifier: MIT

defmodule TaskweftAcp.Session.Store do
  @moduledoc """
  The event log behind every session, and the registry of sessions and executors.

  One adapter is primary and one is the fallback, chosen by configuration and switched
  only on a named failure class: `TaskweftAcp.Session.Store.Vfs` drives fabric-store's
  `weft_fdb` databases (or plain SQLite files) through a Port; `TaskweftAcp.Session.Store.Bao`
  reaches the same tables through OpenBao's sqlite-fdb secrets engine;
  `TaskweftAcp.Session.Store.Memory` is the test double.
  """

  use GenServer

  @type event :: map()

  @callback open(keyword()) :: {:ok, term()} | {:error, term()}
  @callback create_session(term(), String.t(), map()) :: {:ok, term()} | {:error, term()}
  @callback append(term(), String.t(), event()) ::
              {:ok, non_neg_integer(), term()} | {:error, term()}
  @callback events(term(), String.t(), non_neg_integer()) ::
              {:ok, [event()], term()} | {:error, term()}
  @callback sessions(term(), String.t() | :all) :: {:ok, [map()], term()} | {:error, term()}
  @callback close(term()) :: :ok

  @fallback_errors [:unreachable, :fence_lost]

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  def create_session(store \\ __MODULE__, id, meta),
    do: GenServer.call(store, {:create, id, meta})

  def append(store \\ __MODULE__, id, event), do: GenServer.call(store, {:append, id, event})
  def events(store \\ __MODULE__, id, from \\ 0), do: GenServer.call(store, {:events, id, from})
  def sessions(store \\ __MODULE__, cwd \\ :all), do: GenServer.call(store, {:sessions, cwd})
  def status(store \\ __MODULE__), do: GenServer.call(store, :status)

  @impl true
  def init(opts) do
    primary =
      Keyword.get(opts, :adapter, adapter_for(Application.get_env(:taskweft_acp, :store, :plain)))

    fallback = Keyword.get(opts, :fallback, nil)
    adapter_opts = Keyword.get(opts, :adapter_opts, [])

    case primary.open(adapter_opts) do
      {:ok, state} ->
        {:ok,
         %{
           adapter: primary,
           state: state,
           primary: primary,
           fallback: fallback,
           opts: adapter_opts,
           mode: :primary
         }}

      {:error, reason} when fallback != nil ->
        switch(
          %{
            adapter: primary,
            state: nil,
            primary: primary,
            fallback: fallback,
            opts: adapter_opts,
            mode: :primary
          },
          reason
        )

      # The hosted door stays up with the reason on /health; a desk task stops with it.
      {:error, reason} ->
        if Keyword.get(opts, :on_unreachable, :stop) == :degrade do
          {:ok,
           %{
             adapter: primary,
             state: nil,
             primary: primary,
             fallback: nil,
             opts: adapter_opts,
             mode: {:unreachable, reason}
           }}
        else
          {:stop, {:store_unreachable, reason}}
        end
    end
  end

  @impl true
  def handle_call(:status, _from, s), do: {:reply, %{adapter: s.adapter, mode: s.mode}, s}

  def handle_call({:create, id, meta}, _from, s),
    do: run(s, &s.adapter.create_session(&1, id, meta))

  def handle_call({:append, id, event}, _from, s), do: run(s, &s.adapter.append(&1, id, event))
  def handle_call({:events, id, from}, _from, s), do: run(s, &s.adapter.events(&1, id, from))
  def handle_call({:sessions, cwd}, _from, s), do: run(s, &s.adapter.sessions(&1, cwd))

  defp run(%{mode: {:unreachable, reason}} = s, _fun),
    do: {:reply, {:error, {:unreachable, reason}}, s}

  defp run(s, fun) do
    case fun.(s.state) do
      {:ok, state} ->
        {:reply, :ok, %{s | state: state}}

      {:ok, value, state} ->
        {:reply, {:ok, value}, %{s | state: state}}

      {:error, {class, _} = reason}
      when class in @fallback_errors and s.fallback != nil and s.mode == :primary ->
        case switch(s, reason) do
          {:ok, s2} -> run(s2, fun)
          {:stop, why} -> {:reply, {:error, why}, s}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, s}
    end
  end

  # The switch itself is written through the fallback first, so the log says why.
  defp switch(s, reason) do
    case s.fallback.open(s.opts) do
      {:ok, state} ->
        {:ok, %{s | adapter: s.fallback, state: state, mode: :fallback}}
        |> tap(fn _ -> :logger.warning("store fallback: #{inspect(reason)}") end)

      {:error, why} ->
        {:stop, {:store_unreachable, {reason, why}}}
    end
  end

  defp adapter_for(:memory), do: TaskweftAcp.Session.Store.Memory
  defp adapter_for(_plain_or_fabric), do: TaskweftAcp.Session.Store.Vfs
end
