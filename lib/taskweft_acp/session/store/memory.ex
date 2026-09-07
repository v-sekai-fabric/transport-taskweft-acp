# Copyright (c) 2026 K. S. Ernest (iFire) Lee
# SPDX-License-Identifier: MIT

defmodule TaskweftAcp.Session.Store.Memory do
  @moduledoc "The test double: the same log shape in process memory, lost on exit."

  @behaviour TaskweftAcp.Session.Store

  @impl true
  def open(opts), do: {:ok, %{sessions: %{}, events: %{}, fail: Keyword.get(opts, :fail)}}

  @impl true
  def create_session(%{fail: {:create, reason}} = s, _id, _meta),
    do: {:error, reason} |> tap(fn _ -> s end)

  def create_session(s, id, meta) do
    row = Map.merge(%{"id" => id, "created_at" => TaskweftAcp.Session.now()}, meta)
    {:ok, %{s | sessions: Map.put(s.sessions, id, row), events: Map.put_new(s.events, id, [])}}
  end

  @impl true
  def append(%{fail: {:append, reason}}, _id, _event), do: {:error, reason}

  def append(s, id, event) do
    log = Map.get(s.events, id, [])
    ordinal = length(log) + 1
    row = Map.put(event, "ordinal", ordinal)
    {:ok, ordinal, %{s | events: Map.put(s.events, id, log ++ [row])}}
  end

  @impl true
  def events(s, id, from) do
    {:ok, s.events |> Map.get(id, []) |> Enum.filter(&(&1["ordinal"] > from)), s}
  end

  @impl true
  def sessions(s, cwd) do
    rows =
      s.sessions
      |> Map.values()
      |> Enum.filter(&(cwd == :all or &1["cwd"] == cwd))
      |> Enum.sort_by(& &1["created_at"], :desc)

    {:ok, rows, s}
  end

  @impl true
  def close(_s), do: :ok
end
