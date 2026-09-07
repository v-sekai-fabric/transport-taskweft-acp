# Copyright (c) 2026 K. S. Ernest (iFire) Lee
# SPDX-License-Identifier: MIT

defmodule TaskweftAcp.FabricEnvTest do
  use ExUnit.Case, async: false

  alias TaskweftAcp.FabricEnv

  @inputs ~w(FDB_TLS_CERT_B64 FDB_TLS_KEY_B64 FDB_TLS_CA_B64 WEFT_FDB_CLUSTER_B64)
  @outputs ~w(FDB_TLS_CERTIFICATE_FILE FDB_TLS_KEY_FILE FDB_TLS_CA_FILE FDB_TLS_VERIFY_PEERS WEFT_FDB_CLUSTER_FILE)

  setup do
    saved = for v <- @inputs ++ @outputs, do: {v, System.get_env(v)}
    for v <- @inputs ++ @outputs, do: System.delete_env(v)

    dir =
      Path.join(System.tmp_dir!(), "taskweft_acp_fabric_#{System.unique_integer([:positive])}")

    on_exit(fn ->
      for {v, val} <- saved, do: if(val, do: System.put_env(v, val), else: System.delete_env(v))
      File.rm_rf(dir)
    end)

    %{dir: dir}
  end

  test "nothing given is :none and sets nothing", %{dir: dir} do
    assert :none = FabricEnv.materialise(dir)
    refute File.exists?(dir)
    assert System.get_env("WEFT_FDB_CLUSTER_FILE") == nil
  end

  test "all four land as files and the libfdb_c variables point at them", %{dir: dir} do
    System.put_env("FDB_TLS_CERT_B64", Base.encode64("CERT"))
    System.put_env("FDB_TLS_KEY_B64", Base.encode64("KEY") <> "\n")
    System.put_env("FDB_TLS_CA_B64", Base.encode64("CA"))
    System.put_env("WEFT_FDB_CLUSTER_B64", Base.encode64("weft:abc@[fdaa::1]:4500:tls"))

    assert :ok = FabricEnv.materialise(dir)
    assert File.read!(System.get_env("FDB_TLS_CERTIFICATE_FILE")) == "CERT"
    assert File.read!(System.get_env("FDB_TLS_KEY_FILE")) == "KEY"
    assert File.read!(System.get_env("FDB_TLS_CA_FILE")) == "CA"
    assert File.read!(System.get_env("WEFT_FDB_CLUSTER_FILE")) == "weft:abc@[fdaa::1]:4500:tls"
    assert System.get_env("FDB_TLS_VERIFY_PEERS") =~ "S.CN>=fdb-"
  end

  test "a partial set is a named failure, not a silent plain mode", %{dir: dir} do
    System.put_env("FDB_TLS_CERT_B64", Base.encode64("CERT"))
    assert {:error, message} = FabricEnv.materialise(dir)
    assert message =~ "FDB_TLS_KEY_B64"
    assert message =~ "WEFT_FDB_CLUSTER_B64"
    assert System.get_env("WEFT_FDB_CLUSTER_FILE") == nil
  end

  test "a value that is not base64 is named", %{dir: dir} do
    for v <- @inputs, do: System.put_env(v, Base.encode64("x"))
    System.put_env("FDB_TLS_KEY_B64", "not base64!")
    assert {:error, "FDB_TLS_KEY_B64 is not base64"} = FabricEnv.materialise(dir)
    assert System.get_env("WEFT_FDB_CLUSTER_FILE") == nil
  end
end
