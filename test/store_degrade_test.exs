# Copyright (c) 2026 K. S. Ernest (iFire) Lee
# SPDX-License-Identifier: MIT

defmodule TaskweftAcp.StoreDegradeTest do
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

  test "an adapter that raises while opening degrades the hosted store with the message" do
    {:ok, store} = Store.start_link(name: nil, adapter: RaisingAdapter, on_unreachable: :degrade)
    assert %{mode: {:degraded, {:unreachable, {:exception, message}}}} = Store.status(store)
    assert message =~ "x.sql"
    assert {:error, {:unreachable, {:exception, _}}} = Store.sessions(store, :all)
  end

  test "the same exception stops a desk store with the message" do
    Process.flag(:trap_exit, true)

    assert {:error, {:store_unreachable, {:unreachable, {:exception, message}}}} =
             Store.start_link(name: nil, adapter: RaisingAdapter)

    assert message =~ "x.sql"
  end
end
