# Copyright (c) 2026 K. S. Ernest (iFire) Lee
# SPDX-License-Identifier: MIT

defmodule RepoChores do
  use Taskweft.DSL

  @name "repo_chores"

  @variables %{
    formatted: %{type: :bool, init: %{repo: false}},
    built: %{type: :bool, init: %{repo: false}},
    tests_pass: %{type: :bool, init: %{repo: false}},
    committed: %{type: :bool, init: %{repo: false}},
    dirty: %{type: :bool, init: %{repo: true}}
  }

  @actions %{
    run_format: %{
      params: [],
      body: [
        %{pointer_set: "/formatted/repo", value: true},
        %{pointer_set: "/dirty/repo", value: true}
      ]
    },
    run_build: %{
      params: [],
      body: [%{pointer_set: "/built/repo", value: true}]
    },
    run_tests: %{
      params: [],
      body: [
        %{eval: %{type: "math/eq", a: %{pointer_get: "/built/repo"}, b: true}},
        %{pointer_set: "/tests_pass/repo", value: true}
      ]
    },
    git_add: %{
      params: [],
      body: [%{eval: %{type: "math/eq", a: %{pointer_get: "/dirty/repo"}, b: true}}]
    },
    git_commit: %{
      params: [:msg],
      body: [
        %{eval: %{type: "math/eq", a: %{pointer_get: "/tests_pass/repo"}, b: true}},
        %{pointer_set: "/committed/repo", value: true},
        %{pointer_set: "/dirty/repo", value: false}
      ]
    },
    read_file: %{params: [:path], body: []},
    write_file: %{
      params: [:path],
      body: [%{pointer_set: "/dirty/repo", value: true}]
    }
  }

  @methods %{
    formatted: %{
      params: [],
      alternatives: [
        %{
          name: :already,
          check: [%{eval: %{type: "math/eq", a: %{pointer_get: "/formatted/repo"}, b: true}}],
          subtasks: []
        },
        %{name: :format, subtasks: [["run_format"]]}
      ]
    },
    built: %{
      params: [],
      alternatives: [
        %{
          name: :already,
          check: [%{eval: %{type: "math/eq", a: %{pointer_get: "/built/repo"}, b: true}}],
          subtasks: []
        },
        %{name: :build, subtasks: [["run_build"]]}
      ]
    },
    tests_pass: %{
      params: [],
      alternatives: [
        %{
          name: :already,
          check: [%{eval: %{type: "math/eq", a: %{pointer_get: "/tests_pass/repo"}, b: true}}],
          subtasks: []
        },
        %{name: :build_then_test, subtasks: [["run_build"], ["run_tests"]]}
      ]
    },
    committed: %{
      params: [:msg],
      alternatives: [
        %{
          name: :full,
          subtasks: [["formatted"], ["tests_pass"], ["git_add"], ["git_commit", "{msg}"]]
        }
      ]
    }
  }

  @todo_list []

  # How each action reaches the editor. taskweft ignores this attribute; TaskweftAcp.Domain
  # reads it by the same literal AST walk, never by evaluating the file.
  @exec %{
    run_format: %{kind: :terminal, command: "mix", args: ["format"]},
    run_build: %{kind: :terminal, command: "mix", args: ["compile", "--warnings-as-errors"]},
    run_tests: %{kind: :terminal, command: "mix", args: ["test"]},
    git_add: %{kind: :terminal, command: "git", args: ["add", "-A"]},
    git_commit: %{kind: :terminal, command: "git", args: ["commit", "-m", "{msg}"]},
    read_file: %{kind: :read, path: "{path}"},
    write_file: %{kind: :write, path: "{path}"}
  }
end
