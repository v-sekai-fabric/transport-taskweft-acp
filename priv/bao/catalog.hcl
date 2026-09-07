# The catalog OpenBao's sqlite-fdb engine loads for the fallback store
# (BAO_SQLITE_FDB_CATALOG). The statement names are the ones
# TaskweftAcp.Session.Store.Bao sends; the schema blocks are this repository's
# migrations, applied by the plugin when it opens a database, so the two adapters
# share one source for the tables.

schema "acp_registry" {
  file = "../migrations/registry.sql"
}

schema "acp_*" {
  file = "../migrations/session.sql"
}

exec "acp_session_insert" {
  sql  = "INSERT INTO acp_session (session_id, cwd, created_at) VALUES (?, ?, ?)"
  args = ["session_id", "cwd", "created_at"]
}

exec "acp_event_append" {
  sql  = "INSERT INTO acp_event (ordinal, at, direction, method, payload) VALUES ((SELECT COALESCE(MAX(ordinal), 0) + 1 FROM acp_event), ?, ?, ?, ?) RETURNING ordinal"
  args = ["at", "direction", "method", "payload"]
}

query "acp_events_after" {
  sql  = "SELECT ordinal, at, direction, method, payload FROM acp_event WHERE ordinal > ? ORDER BY ordinal"
  args = ["after"]
}

query "acp_sessions_all" {
  sql = "SELECT session_id, cwd, created_at FROM acp_session ORDER BY created_at DESC"
}

query "acp_sessions_by_cwd" {
  sql  = "SELECT session_id, cwd, created_at FROM acp_session WHERE cwd = ? ORDER BY created_at DESC"
  args = ["cwd"]
}
