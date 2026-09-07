# Copyright (c) 2026 K. S. Ernest (iFire) Lee
# SPDX-License-Identifier: MIT

defmodule TaskweftAcp.FakeBao do
  @moduledoc """
  OpenBao's sqlite-fdb mount as the fallback adapter sees it: the token header checked,
  the five catalog names served over a map, an exec name refused on query/ and a query
  name on exec/, `auth/token/lookup-self` answering the token's policies, and every store
  call recorded in order for the test to read back.
  """

  use Plug.Router

  plug(:match)
  plug(Plug.Parsers, parsers: [:json], json_decoder: Jason, pass: ["*/*"])
  plug(:dispatch)

  @queries ~w(acp_events_after acp_sessions_all acp_sessions_by_cwd)
  @execs ~w(acp_session_insert acp_event_append)

  def start(token, opts \\ []) do
    policies = Keyword.get(opts, :policies, ["default"])

    {:ok, db} =
      Agent.start(fn ->
        %{token: token, policies: policies, sessions: [], events: %{}, calls: []}
      end)

    ref = :"fake_bao_#{System.unique_integer([:positive])}"
    {:ok, _} = Plug.Cowboy.http(__MODULE__, [db: db], port: 0, ip: {127, 0, 0, 1}, ref: ref)
    %{db: db, ref: ref, url: "http://127.0.0.1:#{:ranch.get_port(ref)}"}
  end

  def stop(%{ref: ref, db: db}) do
    _ = Plug.Cowboy.shutdown(ref)
    Agent.stop(db)
  end

  def calls(db), do: Agent.get(db, & &1.calls)

  def call(conn, opts) do
    conn |> assign(:db, Keyword.fetch!(opts, :db)) |> super(opts)
  end

  get "/v1/sqlite-fdb/query/:db/:name" do
    serve(conn, :query, db, name, conn.params)
  end

  post "/v1/sqlite-fdb/exec/:db/:name" do
    serve(conn, :exec, db, name, conn.params)
  end

  post "/v1/auth/token/lookup-self" do
    agent = conn.assigns.db

    if List.first(get_req_header(conn, "x-vault-token")) == Agent.get(agent, & &1.token) do
      data = %{
        "policies" => Agent.get(agent, & &1.policies),
        "ttl" => 60,
        "display_name" => "fake"
      }

      send_json(conn, 200, %{"data" => data})
    else
      send_json(conn, 403, %{"errors" => ["permission denied"]})
    end
  end

  match _ do
    send_json(conn, 404, %{"errors" => ["no handler for #{conn.request_path}"]})
  end

  defp serve(conn, kind, db, name, params) do
    agent = conn.assigns.db
    token = List.first(get_req_header(conn, "x-vault-token"))
    Agent.update(agent, &%{&1 | calls: &1.calls ++ [{kind, db, name, params}]})

    cond do
      token != Agent.get(agent, & &1.token) ->
        send_json(conn, 403, %{"errors" => ["permission denied"]})

      kind == :query and name in @execs ->
        send_json(conn, 400, %{"errors" => ["#{name} is an exec; it does not run through query"]})

      kind == :exec and name in @queries ->
        send_json(conn, 400, %{"errors" => ["#{name} is a query; it does not run through exec"]})

      name not in @queries and name not in @execs ->
        send_json(conn, 400, %{"errors" => ["#{name} not registered"]})

      not Regex.match?(~r/^[A-Za-z0-9_-]+$/, db) ->
        send_json(conn, 400, %{"errors" => ["database name #{inspect(db)} is not [A-Za-z0-9_-]"]})

      true ->
        case Agent.get_and_update(agent, &run(&1, name, db, params)) do
          {:error, msg} ->
            send_json(conn, 500, %{"errors" => [msg]})

          data ->
            send_json(conn, 200, %{"data" => Map.merge(%{"name" => name, "db" => db}, data)})
        end
    end
  end

  defp run(st, "acp_session_insert", "acp_registry", p) do
    row = %{"session_id" => p["session_id"], "cwd" => p["cwd"], "created_at" => p["created_at"]}
    {%{"rows" => [], "changes" => 1}, %{st | sessions: st.sessions ++ [row]}}
  end

  defp run(st, "acp_event_append", db, p) do
    log = Map.get(st.events, db, [])
    ordinal = length(log) + 1

    row = %{
      "ordinal" => ordinal,
      "at" => p["at"],
      "direction" => p["direction"],
      "method" => p["method"],
      "payload" => p["payload"]
    }

    {%{"rows" => [%{"ordinal" => ordinal}], "changes" => 1},
     %{st | events: Map.put(st.events, db, log ++ [row])}}
  end

  defp run(st, "acp_events_after", db, p) do
    from = to_int(p["after"])
    {%{"rows" => st.events |> Map.get(db, []) |> Enum.filter(&(&1["ordinal"] > from))}, st}
  end

  defp run(st, "acp_sessions_all", "acp_registry", _p) do
    {%{"rows" => Enum.sort_by(st.sessions, & &1["created_at"], :desc)}, st}
  end

  defp run(st, "acp_sessions_by_cwd", "acp_registry", p) do
    rows =
      st.sessions
      |> Enum.filter(&(&1["cwd"] == p["cwd"]))
      |> Enum.sort_by(& &1["created_at"], :desc)

    {%{"rows" => rows}, st}
  end

  defp run(st, name, db, _p), do: {{:error, "no table for #{name} in #{db}"}, st}

  defp to_int(v) when is_integer(v), do: v
  defp to_int(v) when is_binary(v), do: String.to_integer(v)

  defp send_json(conn, status, body) do
    conn |> put_resp_content_type("application/json") |> send_resp(status, Jason.encode!(body))
  end
end
