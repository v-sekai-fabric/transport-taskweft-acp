# Copyright (c) 2026 K. S. Ernest (iFire) Lee
# SPDX-License-Identifier: MIT

defmodule TaskweftAcp.Session.Store.Bao do
  @moduledoc """
  The fallback store: the same tables reached through OpenBao's sqlite-fdb secrets engine.
  Every call is a catalog name from `priv/bao/catalog.hcl`, never SQL. The plugin opens
  `acp_<name>` databases on demand and takes their fence, so a stale primary writer is
  refused rather than raced.
  """

  @behaviour TaskweftAcp.Session.Store

  alias TaskweftAcp.Session

  defstruct req: nil, mount: "sqlite-fdb"

  @impl true
  def open(opts) do
    addr = Keyword.get(opts, :bao_addr) || System.get_env("BAO_ADDR")
    token = Keyword.get(opts, :bao_token) || System.get_env("BAO_TOKEN")

    mount =
      Keyword.get(opts, :bao_mount, Application.get_env(:taskweft_acp, :bao_mount, "sqlite-fdb"))

    cond do
      addr in [nil, ""] ->
        {:error, {:unreachable, :no_bao_addr}}

      token in [nil, ""] ->
        {:error, {:unreachable, :no_bao_token}}

      true ->
        req =
          Req.new(
            base_url: addr,
            headers: [{"x-vault-token", token}],
            connect_options: connect_options(),
            retry: false,
            receive_timeout: 10_000
          )

        s = %__MODULE__{req: req, mount: mount}

        case query(s, "acp_registry", "acp_sessions_all", %{}) do
          {:ok, _} -> {:ok, s}
          {:error, _} = error -> error
        end
    end
  end

  @impl true
  def create_session(s, id, meta) do
    with :ok <- valid_id(id),
         {:ok, _} <-
           exec(s, "acp_registry", "acp_session_insert", %{
             "session_id" => id,
             "cwd" => meta["cwd"] || "",
             "created_at" => meta["created_at"] || Session.now()
           }) do
      {:ok, s}
    end
  end

  @impl true
  def append(s, id, event) do
    with :ok <- valid_id(id),
         {:ok, %{"rows" => [%{"ordinal" => ordinal}]}} <-
           exec(s, "acp_#{id}", "acp_event_append", %{
             "at" => event["at"],
             "direction" => event["direction"],
             "method" => event["method"],
             "payload" => Jason.encode!(event["payload"])
           }) do
      {:ok, ordinal, s}
    else
      {:ok, other} -> {:error, {:sql, "bao: acp_event_append returned #{inspect(other)}"}}
      error -> error
    end
  end

  @impl true
  def events(s, id, from) do
    with :ok <- valid_id(id),
         {:ok, %{"rows" => rows}} <-
           query(s, "acp_#{id}", "acp_events_after", %{"after" => from}) do
      {:ok, Enum.map(rows, &event_row/1), s}
    else
      {:ok, other} -> {:error, {:sql, "bao: acp_events_after returned #{inspect(other)}"}}
      error -> error
    end
  end

  @impl true
  def sessions(s, cwd) do
    result =
      case cwd do
        :all -> query(s, "acp_registry", "acp_sessions_all", %{})
        cwd -> query(s, "acp_registry", "acp_sessions_by_cwd", %{"cwd" => cwd})
      end

    with {:ok, %{"rows" => rows}} <- result do
      rows =
        for row <- rows do
          %{"id" => row["session_id"], "cwd" => row["cwd"], "created_at" => row["created_at"]}
        end

      {:ok, rows, s}
    else
      {:ok, other} -> {:error, {:sql, "bao: sessions returned #{inspect(other)}"}}
      error -> error
    end
  end

  @impl true
  def close(_s), do: :ok

  defp event_row(row) do
    %{
      "ordinal" => row["ordinal"],
      "at" => row["at"],
      "direction" => row["direction"],
      "method" => row["method"],
      "payload" => Jason.decode!(row["payload"])
    }
  end

  defp valid_id(id) do
    if Regex.match?(~r/^[A-Za-z0-9_-]+$/, id),
      do: :ok,
      else: {:error, {:sql, "session id #{inspect(id)} is not [A-Za-z0-9_-]"}}
  end

  defp query(s, db, name, params),
    do: call(s, :get, "/v1/#{s.mount}/query/#{db}/#{name}", params: params)

  defp exec(s, db, name, params),
    do: call(s, :post, "/v1/#{s.mount}/exec/#{db}/#{name}", json: params)

  defp call(s, method, path, opts) do
    case Req.request(s.req, [method: method, url: path] ++ opts) do
      {:ok, %Req.Response{status: 200, body: %{"data" => data}}} ->
        {:ok, data}

      {:ok, %Req.Response{status: 200, body: body}} ->
        {:error, {:sql, "bao: no data in #{inspect(body)}"}}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, classify("bao: HTTP #{status} #{errors(body)}")}

      {:error, reason} ->
        {:error, {:unreachable, reason}}
    end
  end

  defp errors(%{"errors" => list}) when is_list(list), do: Enum.join(list, "; ")
  defp errors(body), do: inspect(body)

  # The fence refusal is the one error class that changes ownership; the rest are plain.
  defp classify(msg) do
    cond do
      msg =~ "readonly" or msg =~ "SQLITE_READONLY" -> {:fence_lost, msg}
      msg =~ "FoundationDB" -> {:unreachable, msg}
      true -> {:sql, msg}
    end
  end

  defp connect_options do
    case System.get_env("BAO_CACERT") do
      ca when ca in [nil, ""] ->
        []

      ca ->
        sni =
          case System.get_env("BAO_TLS_SERVER_NAME") do
            name when name in [nil, ""] -> []
            name -> [server_name_indication: String.to_charlist(name)]
          end

        [transport_opts: [cacertfile: ca, verify: :verify_peer] ++ sni]
    end
  end
end
