-- Copyright (c) 2026 K. S. Ernest (iFire) Lee
-- SPDX-License-Identifier: MIT
-- One database per ACP session: the event log and its satellites. Essential Tuple Normal
-- Form: no nulls, satellites for facts that are not always present, no derived columns.
CREATE TABLE IF NOT EXISTS acp_event (
  ordinal INTEGER PRIMARY KEY,
  at TEXT NOT NULL,
  direction TEXT NOT NULL CHECK (direction IN ('client_to_agent', 'agent_to_client')),
  method TEXT NOT NULL,
  payload TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS acp_event_method ON acp_event (method);
CREATE TABLE IF NOT EXISTS acp_prompt_stop (
  prompt_ordinal INTEGER PRIMARY KEY,
  event_ordinal INTEGER NOT NULL REFERENCES acp_event (ordinal),
  stop_reason TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS acp_allow_always (
  action TEXT PRIMARY KEY,
  event_ordinal INTEGER NOT NULL REFERENCES acp_event (ordinal)
);
