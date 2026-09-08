# Copyright (c) 2026 K. S. Ernest (iFire) Lee
# SPDX-License-Identifier: MIT

# The body's discrete reactions as a taskweft domain (RFD 2237). The planner turns a
# goal such as `greet` into a step sequence; `mix taskweft_acp.plan_sgd` exports it and
# taskweft-fbd-compiler lifts the steps into a triggered chain of output writes and
# holds inside a scan controller. Continuous logic (stick deadzone, speed limit,
# tracker timeout) is written in the controller's text form, not here.
defmodule AvatarReactions do
  use Taskweft.DSL

  @name "avatar_reactions"

  @variables %{
    facing_set: %{type: :bool, init: %{body: false}},
    waving: %{type: :bool, init: %{body: false}},
    greeted: %{type: :bool, init: %{body: false}},
    idle: %{type: :bool, init: %{body: true}}
  }

  @actions %{
    face_stick: %{
      params: [],
      body: [%{pointer_set: "/facing_set/body", value: true}]
    },
    start_wave: %{
      params: [],
      body: [
        %{eval: %{type: "math/eq", a: %{pointer_get: "/facing_set/body"}, b: true}},
        %{pointer_set: "/waving/body", value: true},
        %{pointer_set: "/idle/body", value: false}
      ]
    },
    hold_wave: %{
      params: [:seconds],
      body: [%{eval: %{type: "math/eq", a: %{pointer_get: "/waving/body"}, b: true}}]
    },
    stop_wave: %{
      params: [],
      body: [
        %{pointer_set: "/waving/body", value: false},
        %{pointer_set: "/greeted/body", value: true},
        %{pointer_set: "/idle/body", value: true}
      ]
    },
    freeze_chains: %{
      params: [],
      body: []
    }
  }

  @methods %{
    faced: %{
      params: [],
      alternatives: [
        %{
          name: :already,
          check: [%{eval: %{type: "math/eq", a: %{pointer_get: "/facing_set/body"}, b: true}}],
          subtasks: []
        },
        %{name: :face, subtasks: [["face_stick"]]}
      ]
    },
    greet: %{
      params: [],
      alternatives: [
        %{
          name: :already,
          check: [%{eval: %{type: "math/eq", a: %{pointer_get: "/greeted/body"}, b: true}}],
          subtasks: []
        },
        %{name: :wave, subtasks: [["faced"], ["start_wave"], ["hold_wave", "2"], ["stop_wave"]]}
      ]
    }
  }

  @todo_list []

  # `set` writes a controller output while the step is active; `hold` keeps the
  # step active for the given seconds. The lift turns each into blocks.
  @exec %{
    face_stick: %{kind: :set, path: "face_from_stick", args: ["TRUE"]},
    start_wave: %{kind: :set, path: "style", args: ["3"]},
    hold_wave: %{kind: :hold, path: "", args: ["{seconds}"]},
    stop_wave: %{kind: :set, path: "style", args: ["0"]},
    freeze_chains: %{kind: :set, path: "chain_frozen", args: ["TRUE"]}
  }
end
