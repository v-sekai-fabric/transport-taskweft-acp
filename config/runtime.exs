# Copyright (c) 2026 K. S. Ernest (iFire) Lee
# SPDX-License-Identifier: MIT

import Config

# The store mode is chosen explicitly: plain (a local SQLite file per session), fabric
# (weft_fdb databases on the cluster) or memory (tests and smoke runs; lost on exit).
case System.get_env("TASKWEFT_ACP_STORE") do
  nil -> :ok
  "plain" -> config(:taskweft_acp, store: :plain)
  "fabric" -> config(:taskweft_acp, store: :fabric)
  "memory" -> config(:taskweft_acp, store: :memory)
  other -> raise "TASKWEFT_ACP_STORE=#{other}: expected plain, fabric or memory"
end

# The fallback is chosen explicitly too: bao (OpenBao's sqlite-fdb engine) or unset.
case System.get_env("TASKWEFT_ACP_STORE_FALLBACK") do
  nil -> :ok
  "bao" -> config(:taskweft_acp, store_fallback: TaskweftAcp.Session.Store.Bao)
  other -> raise "TASKWEFT_ACP_STORE_FALLBACK=#{other}: expected bao or unset"
end

if port = System.get_env("PORT"), do: config(:taskweft_acp, port: String.to_integer(port))
if System.get_env("TASKWEFT_ACP_SERVE") == "1", do: config(:taskweft_acp, serve: true)
