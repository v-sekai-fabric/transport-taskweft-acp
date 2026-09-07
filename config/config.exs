# Copyright (c) 2026 K. S. Ernest (iFire) Lee
# SPDX-License-Identifier: MIT

import Config

config :logger, level: :info

# Exactly one store mode, never defaulted: `plain` (a local SQLite file per session, the
# desk and CI) or `fabric` (weft_fdb databases on the cluster, the hosted door).
config :taskweft_acp,
  store: :plain,
  store_dir: ".taskweft-acp",
  serve: false,
  port: 8080

if config_env() == :prod, do: config(:taskweft_acp, serve: true, store: :fabric)
if config_env() == :test, do: config(:logger, level: :warning)
