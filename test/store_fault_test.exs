# Copyright (c) 2026 K. S. Ernest (iFire) Lee
# SPDX-License-Identifier: MIT

defmodule TaskweftAcp.StoreFaultTest do
  use ExUnit.Case, async: false

  alias TaskweftAcp.Session.Store

  defmodule RaisingAdapter do
    @moduledoc false
    @behaviour Store

    @impl true
    def open(_opts), do: raise(File.Error, reason: :enoent, action: "read file", path: "x.sql")
    @impl true
    def create_session(s, _id, _meta), do: {:ok, s}
    @impl true
    def append(s, _id, _event), do: {:ok, 1, s}
    @impl true
    def events(s, _id, _from), do: {:ok, [], s}
    @impl true
    def sessions(s, _cwd), do: {:ok, [], s}
    @impl true
    def close(_s), do: :ok
  end

  # Only an unreachable cluster degrades. A defect while opening (a missing migration,
  # a bad build) faults the store, and with it the release, even when degrading is allowed.
  test "an adapter that raises while opening faults the store, degrade mode or not" do
    Process.flag(:trap_exit, true)

    assert {:error, {%File.Error{path: "x.sql"}, _stack}} =
             Store.start_link(name: nil, adapter: RaisingAdapter, on_unreachable: :degrade)

    assert {:error, {%File.Error{path: "x.sql"}, _stack}} =
             Store.start_link(name: nil, adapter: RaisingAdapter)
  end
end
