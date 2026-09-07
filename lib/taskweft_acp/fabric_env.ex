# Copyright (c) 2026 K. S. Ernest (iFire) Lee
# SPDX-License-Identifier: MIT

defmodule TaskweftAcp.FabricEnv do
  @moduledoc """
  The cluster credentials for fabric mode, from the secrets RFD 2134 gives a client
  service: `FDB_TLS_CERT_B64`, `FDB_TLS_KEY_B64`, `FDB_TLS_CA_B64` and the cluster string
  in `WEFT_FDB_CLUSTER_B64`. They are written to files before the store helper starts, and
  libfdb_c reads them through the `FDB_TLS_*` variables it already understands.
  """

  @verify_rule "Check.Valid=1,S.CN>=fdb-,S.CN<=.chibifire.com"

  @files [
    {"FDB_TLS_CERT_B64", "cert.pem", "FDB_TLS_CERTIFICATE_FILE"},
    {"FDB_TLS_KEY_B64", "key.pem", "FDB_TLS_KEY_FILE"},
    {"FDB_TLS_CA_B64", "ca.pem", "FDB_TLS_CA_FILE"},
    {"WEFT_FDB_CLUSTER_B64", "fdb.cluster", "WEFT_FDB_CLUSTER_FILE"}
  ]

  @doc """
  `:none` when no credential variable is set, `:ok` when all four landed as files with the
  libfdb_c variables pointing at them, and an error naming the gap when the set is partial
  or a value is not base64. A partial set fails the boot rather than falling back to plain.
  """
  @spec materialise(String.t()) :: :none | :ok | {:error, String.t()}
  def materialise(dir \\ default_dir()) do
    vars = Enum.map(@files, &elem(&1, 0))
    given = for v <- vars, val = System.get_env(v), val != "", do: {v, val}

    cond do
      given == [] ->
        :none

      length(given) < length(vars) ->
        missing = vars -- Enum.map(given, &elem(&1, 0))
        {:error, "fabric credentials are partial: missing " <> Enum.join(missing, ", ")}

      true ->
        write_all(dir, Map.new(given))
    end
  end

  defp write_all(dir, given) do
    File.mkdir_p!(dir)

    Enum.reduce_while(@files, :ok, fn {var, name, _}, :ok ->
      case Base.decode64(given[var], ignore: :whitespace) do
        {:ok, bytes} ->
          path = Path.join(dir, name)
          File.write!(path, bytes)
          _ = File.chmod(path, 0o600)
          {:cont, :ok}

        :error ->
          {:halt, {:error, "#{var} is not base64"}}
      end
    end)
    |> case do
      :ok ->
        env = for {_, name, target} <- @files, into: %{}, do: {target, Path.join(dir, name)}
        verify = System.get_env("FDB_TLS_VERIFY_PEERS") || @verify_rule
        System.put_env(Map.put(env, "FDB_TLS_VERIFY_PEERS", verify))
        :ok

      error ->
        error
    end
  end

  defp default_dir, do: Path.join(System.tmp_dir!(), "taskweft-acp-fabric")
end
