-- Copyright (c) 2026 K. S. Ernest (iFire) Lee
-- SPDX-License-Identifier: MIT
-- The registry: which sessions exist, which executors are known, and which executor a
-- session is bound to. Essential Tuple Normal Form: no nulls, satellites not nullable columns.
CREATE TABLE IF NOT EXISTS acp_session (
  session_id TEXT PRIMARY KEY,
  cwd TEXT NOT NULL,
  created_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS acp_session_cwd ON acp_session (cwd, created_at);
CREATE TABLE IF NOT EXISTS acp_executor (
  name TEXT PRIMARY KEY,
  connected_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS acp_executor_label (
  name TEXT NOT NULL REFERENCES acp_executor (name),
  label TEXT NOT NULL,
  PRIMARY KEY (name, label)
);
CREATE TABLE IF NOT EXISTS acp_session_executor (
  session_id TEXT PRIMARY KEY REFERENCES acp_session (session_id),
  name TEXT NOT NULL REFERENCES acp_executor (name),
  bound_at TEXT NOT NULL
);
