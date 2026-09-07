# Copyright (c) 2026 K. S. Ernest (iFire) Lee
# SPDX-License-Identifier: MIT

defmodule TaskweftAcp.Session.Store.Vfs do
  @moduledoc """
  The primary store: one `weft_sql` helper process over a Port, plain SQLite files on a
  desk or `weft_fdb` databases on the cluster, one database per session plus a registry.
  Every write is one SQLite transaction, which in fabric mode is one FoundationDB commit.
  """

  @behaviour TaskweftAcp.Session.Store

  defstruct port: nil, mode: :plain, dir: nil, open: MapSet.new()

  @migrations_dir Path.join(:code.priv_dir(:taskweft_acp), "migrations")

  @impl true
  def open(opts) do
    mode = Keyword.get(opts, :mode, Application.get_env(:taskweft_acp, :store, :plain))
    dir = Keyword.get(opts, :dir, default_dir())
    if mode == :plain, do: File.mkdir_p!(dir)

    with {:ok, exe} <- helper(Keyword.get(opts, :helper)),
         port = Port.open({:spawn_executable, exe}, [:binary, :exit_status, {:line, 1_048_576}]),
         {:ok, %{"ready" => true}} <- read(port),
         state = %__MODULE__{port: port, mode: mode, dir: dir},
         {:ok, state} <- open_db(state, "registry"),
         {:ok, state} <- migrate(state, "registry", "registry.sql") do
      {:ok, state}
    else
      {:error, reason} -> {:error, {:unreachable, reason}}
      {:ok, other} -> {:error, {:unreachable, {:bad_ready, other}}}
    end
  end

  @impl true
  def create_session(s, id, meta) do
    with {:ok, s} <- open_session(s, id),
         {:ok, _} <-
           exec(
             s,
             "registry",
             "INSERT INTO acp_session (session_id, cwd, created_at) VALUES (?, ?, ?)",
             [
               id,
               meta["cwd"] || "",
               meta["created_at"] || TaskweftAcp.Session.now()
             ]
           ) do
      {:ok, s}
    end
  end

  @impl true
  def append(s, id, event) do
    with {:ok, s} <- open_session(s, id),
         {:ok, %{"rows" => [[ordinal]]}} <-
           exec(
             s,
             id,
             """
             INSERT INTO acp_event (ordinal, at, direction, method, payload)
             VALUES ((SELECT COALESCE(MAX(ordinal), 0) + 1 FROM acp_event), ?, ?, ?, ?)
             RETURNING ordinal
             """,
             [event["at"], event["direction"], event["method"], Jason.encode!(event["payload"])]
           ) do
      {:ok, ordinal, s}
    end
  end

  @impl true
  def events(s, id, from) do
    with {:ok, s} <- open_session(s, id),
         {:ok, %{"rows" => rows}} <-
           exec(
             s,
             id,
             "SELECT ordinal, at, direction, method, payload FROM acp_event WHERE ordinal > ? ORDER BY ordinal",
             [from]
           ) do
      events =
        for [ordinal, at, direction, method, payload] <- rows do
          %{
            "ordinal" => ordinal,
            "at" => at,
            "direction" => direction,
            "method" => method,
            "payload" => Jason.decode!(payload)
          }
        end

      {:ok, events, s}
    end
  end

  @impl true
  def sessions(s, cwd) do
    {sql, args} =
      case cwd do
        :all ->
          {"SELECT session_id, cwd, created_at FROM acp_session ORDER BY created_at DESC", []}

        cwd ->
          {"SELECT session_id, cwd, created_at FROM acp_session WHERE cwd = ? ORDER BY created_at DESC",
           [cwd]}
      end

    with {:ok, %{"rows" => rows}} <- exec(s, "registry", sql, args) do
      {:ok, for([id, cwd, at] <- rows, do: %{"id" => id, "cwd" => cwd, "created_at" => at}), s}
    end
  end

  @impl true
  def close(%__MODULE__{port: port}) do
    _ = send_line(port, "X")
    Port.close(port)
    :ok
  catch
    _, _ -> :ok
  end

  defp open_session(%{open: open} = s, id) do
    cond do
      MapSet.member?(open, id) ->
        {:ok, s}

      not Regex.match?(~r/^[A-Za-z0-9_-]+$/, id) ->
        {:error, {:sql, "session id #{inspect(id)} is not [A-Za-z0-9_-]"}}

      true ->
        with {:ok, s} <- open_db(s, id),
             {:ok, s} <- migrate(s, id, "session.sql") do
          {:ok, s}
        end
    end
  end

  defp open_db(s, name) do
    target =
      case s.mode do
        :plain -> Path.join(s.dir, "acp_#{name}.sqlite")
        :fabric -> "acp_#{name}"
      end

    case request(s.port, "O #{name} #{Base.encode64(target)}") do
      {:ok, %{"ok" => true}} -> {:ok, %{s | open: MapSet.put(s.open, name)}}
      {:ok, %{"error" => msg}} -> {:error, classify(msg)}
      {:error, reason} -> {:error, {:unreachable, reason}}
    end
  end

  defp migrate(s, name, file) do
    Path.join(@migrations_dir, file)
    |> File.read!()
    |> String.split(";")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.reduce_while({:ok, s}, fn statement, {:ok, s} ->
      case exec(s, name, statement, []) do
        {:ok, _} -> {:cont, {:ok, s}}
        {:error, _} = e -> {:halt, e}
      end
    end)
  end

  @doc false
  def exec(%__MODULE__{port: port}, name, sql, args) do
    lines = [
      "Q #{name} #{Base.encode64(sql)} #{length(args)}"
      | Enum.map(args, &encode_arg/1)
    ]

    Enum.each(lines, &send_line(port, &1))

    case read(port) do
      {:ok, %{"error" => msg}} -> {:error, classify(msg)}
      {:ok, reply} -> {:ok, reply}
      {:error, reason} -> {:error, {:unreachable, reason}}
    end
  end

  defp encode_arg(nil), do: "n:"
  defp encode_arg(v) when is_integer(v), do: "i:#{v}"
  defp encode_arg(v) when is_float(v), do: "f:#{v}"
  defp encode_arg(v) when is_binary(v), do: "s:" <> Base.encode64(v)
  defp encode_arg(v) when is_boolean(v), do: "i:#{if v, do: 1, else: 0}"

  defp request(port, line) do
    send_line(port, line)
    read(port)
  end

  defp send_line(port, line), do: Port.command(port, line <> "\n")

  defp read(port) do
    receive do
      {^port, {:data, {:eol, line}}} -> Jason.decode(line)
      {^port, {:data, {:noeol, _}}} -> {:error, :line_too_long}
      {^port, {:exit_status, code}} -> {:error, {:helper_exited, code}}
    after
      30_000 -> {:error, :timeout}
    end
  end

  # The fence refusal is the one error class that changes ownership; the rest are plain.
  defp classify(msg) do
    cond do
      msg =~ "readonly" or msg =~ "SQLITE_READONLY" -> {:fence_lost, msg}
      msg =~ "FoundationDB" -> {:unreachable, msg}
      true -> {:sql, msg}
    end
  end

  defp helper(override) do
    exe =
      override ||
        Path.join(
          :code.priv_dir(:taskweft_acp),
          if(match?({:win32, _}, :os.type()), do: "weft_sql.exe", else: "weft_sql")
        )

    if File.exists?(exe), do: {:ok, exe}, else: {:error, {:no_helper, exe}}
  end

  defp default_dir do
    Path.join(File.cwd!(), Application.get_env(:taskweft_acp, :store_dir, ".taskweft-acp"))
  end
end
