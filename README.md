# transport-taskweft-acp

A no-model ACP agent: taskweft plans your repo chores and VS Code or Claude Code runs each step with your permission.

The agent speaks the Agent Client Protocol and holds no language model. A prompt is a
slash command or a short phrase; taskweft turns it into a plan; every step is one ACP
tool call through the client's files and terminals, behind a permission prompt; a
failed step replans from the verified prefix or says that no other decomposition
reaches the goal. The whole session is an event log in the workspace's
FoundationDB-backed SQLite store, so VS Code and Claude Code re-enter the same
session. RFD 2235 carries the argument.

## Prompts

    /run tests pass          plan and execute: build, then test
    /run commit fix the bug  format, build, test, add, commit
    /plan tests pass         plan only, with the explain tree on /explain
    /domain chores.ex        load a taskweft DSL domain from the workspace
    /goal tests_pass=true    set goals; /task <name> <args…> appends a task
    /status  /replan  /export  /help

Plain text works too: "run the tests", "format", "compile it", "commit <message>".

## VS Code

With the ACP Client extension, add the agent to `acp.agents`:

    "taskweft": {
      "command": "cmd",
      "args": ["/c", "set PATH=%USERPROFILE%\\scoop\\apps\\elixir\\current\\bin;%USERPROFILE%\\scoop\\apps\\erlang\\current\\bin;%PATH% && cd /d C:\\fabric-starforged\\1-transport\\transport-taskweft-acp && mix taskweft_acp.agent"]
    }

On a desk with `mix` on the PATH the command is `mix taskweft_acp.agent` in this
directory. The extension shows the plan, each step's permission prompt, the terminal
output and the diffs.

## Claude Code

The same agent behind six MCP tools (`acp_sessions`, `acp_new_session`,
`acp_load_session`, `acp_prompt`, `acp_cancel`, `acp_close`); the prompt tool returns the
run's transcript, so the chat keeps the context:

    claude mcp add --scope user taskweft-acp -- cmd /c "cd /d C:\fabric-starforged\1-transport\transport-taskweft-acp && mix taskweft_acp.mcp"

## Hosted door and executors

On Fly the same bridge is served over HTTPS, gated by an OpenBao token (never GitHub).
Steps run where an executor dialed in, not on the machine:

    TASKWEFT_ACP_TOKEN=$(bao login -no-store -token-only -method=cert name=<role>) \
      mix taskweft_acp.executor --remote wss://weftspun-taskweft-acp.fly.dev/executor --name magi --label gpu:4090

The executor answers permissions from the `taskweft_acp_policy` field of its
`agents/<cn>` secret in bao, overridden key by key by `.taskweft-acp/policy.exs` in
the working directory. Sessions bind to an executor with
`acp_new_session(cwd, executor: "magi")`.

## Export

`/export` writes the plan as a SafeGDScript program for Godot Sandbox
(`.taskweft-acp/<session>.sgd`). The guest holds the plan and the state machine and
cannot run a command or open a file; the host scene under `priv/godot_project`
performs each step it asks for and reports the exit code back.

## Building

    mix deps.get && mix compile          # taskweft's NIF: clang++ through llvm-mingw on Windows, gcc in CI
    make                                 # the store helper, plain mode (libsqlite3-dev)
    make WEFT_FABRIC=1                   # with fabric-store's weft_fdb VFS and libfdb_c
    pixi run weft-sql-win                # the helper on Windows: clang against the pixi SQLite
    mix test && mix dialyzer

A Windows desk builds with llvm-mingw, never Visual Studio: the toolchain unpacked under
`%USERPROFILE%/llvm-mingw`, `clang`, `clang++` and a `mingw32-make` shim on `PATH`, and
`CC=clang CXX=clang++` in the environment. The two launchers under `scripts/` set exactly
that before running `mix`, so the editor and Claude Code entries above carry no
environment of their own.

The hosted door builds from the same tree with `flyctl deploy --remote-only`; the build
context must carry `thirdparty/store` (the goal manifest's linkfiles) because the
Containerfile compiles the helper in fabric mode. `TASKWEFT_ACP_STORE_FALLBACK=bao` makes
OpenBao's sqlite-fdb engine the fallback writer, reached through `priv/bao/catalog.hcl`.

`TASKWEFT_ACP_STORE` is `plain` (SQLite files under `.taskweft-acp/`), `fabric`
(weft_fdb databases on the cluster) or `memory` (tests); it is never defaulted
silently in the release.
