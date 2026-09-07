# Copyright (c) 2026 K. S. Ernest (iFire) Lee
# SPDX-License-Identifier: MIT

defmodule TaskweftAcpDeploy.Auth do
  @moduledoc """
  The hosted door's gate: a bearer token is an OpenBao token, validated by
  `auth/token/lookup-self` against the bao the app is configured for, and admitted when
  its policies include the one the route needs. Lookups are cached for the token's
  remaining TTL (capped), so a run does not ask bao once per step. A bao that cannot be
  reached is 503, never an open door.
  """

  import Plug.Conn

  @behaviour Plug

  @cache :taskweft_acp_auth_cache
  @max_cache_s 300

  @impl Plug
  def init(opts), do: %{policy: Keyword.fetch!(opts, :policy)}

  @impl Plug
  def call(conn, %{policy: policy}) do
    case bearer(conn) do
      nil ->
        refuse(conn, 401, "missing bearer token")

      token ->
        case lookup(token) do
          {:ok, %{policies: policies, display: display}} ->
            if policy in policies do
              conn |> assign(:principal, display) |> assign(:policies, policies)
            else
              refuse(conn, 403, "token lacks policy #{policy}")
            end

          {:error, :invalid} ->
            refuse(conn, 401, "token is not valid at #{bao_addr()}")

          {:error, :unreachable} ->
            refuse(conn, 503, "openbao unreachable")
        end
    end
  end

  @doc "Validate a token outside a Plug (the executor WebSocket handshake)."
  @spec check(String.t() | nil, String.t()) ::
          {:ok, map()} | {:error, :invalid | :unreachable | :forbidden}
  def check(nil, _policy), do: {:error, :invalid}

  def check(token, policy) do
    case lookup(token) do
      {:ok, %{policies: policies} = info} ->
        if policy in policies, do: {:ok, info}, else: {:error, :forbidden}

      {:error, _} = e ->
        e
    end
  end

  defp lookup(token) do
    ensure_cache()
    key = :crypto.hash(:sha256, token)

    case :ets.lookup(@cache, key) do
      [{^key, info, until}] ->
        if System.system_time(:second) < until, do: {:ok, info}, else: fetch(token, key)

      [] ->
        fetch(token, key)
    end
  end

  defp fetch(token, key) do
    url = bao_addr() <> "/v1/auth/token/lookup-self"

    case Req.post(url,
           headers: [{"x-vault-token", token}],
           connect_options: connect_options(),
           receive_timeout: 5_000
         ) do
      {:ok, %{status: 200, body: %{"data" => data}}} ->
        ttl = data["ttl"] || @max_cache_s
        until = System.system_time(:second) + min(max(ttl, 1), @max_cache_s)

        info = %{
          policies: List.wrap(data["policies"]),
          display: data["display_name"] || data["entity_id"] || "token",
          ttl: ttl
        }

        :ets.insert(@cache, {key, info, until})
        {:ok, info}

      {:ok, %{status: status}} when status in [400, 401, 403] ->
        {:error, :invalid}

      {:ok, _} ->
        {:error, :unreachable}

      {:error, _} ->
        {:error, :unreachable}
    end
  end

  defp connect_options do
    case System.get_env("BAO_CACERT") do
      nil -> []
      ca -> [transport_opts: [cacertfile: ca, server_name_indication: bao_sni()]]
    end
  end

  defp bao_sni do
    case System.get_env("BAO_TLS_SERVER_NAME") do
      nil -> :disable
      name -> String.to_charlist(name)
    end
  end

  defp bao_addr, do: System.get_env("BAO_ADDR") || "http://weftspun-bao.internal:8200"

  defp bearer(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> String.trim(token)
      ["bearer " <> token] -> String.trim(token)
      _ -> nil
    end
  end

  defp refuse(conn, status, reason) do
    conn
    |> put_resp_header("www-authenticate", ~s(Bearer realm="taskweft-acp"))
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(%{error: reason}))
    |> halt()
  end

  defp ensure_cache do
    _ =
      if :ets.whereis(@cache) == :undefined,
        do: :ets.new(@cache, [:named_table, :public, :set, read_concurrency: true])

    :ok
  end
end
