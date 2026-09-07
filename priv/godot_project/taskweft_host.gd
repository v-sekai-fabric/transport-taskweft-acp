# Copyright (c) 2026 K. S. Ernest (iFire) Lee
# SPDX-License-Identifier: MIT
#
# The host half of an exported run. The guest program (a taskweft-acp .sgd loaded into
# the Sandbox node) holds the plan and decides the next step; this script performs it on
# the host, asks before each step unless the policy already allows it, and reports the
# exit code back with record(). Nothing in the guest can run a command or open a file.
extends Node

@export var program_path: String = "res://plans/session.sgd"
@export var workspace: String = "."
@export var allow_always: PackedStringArray = []
@onready var sandbox := $Sandbox

func _ready() -> void:
	var program := load(program_path)
	if program == null:
		push_error("taskweft-acp: no program at %s" % program_path)
		return
	sandbox.set("program", program)
	_run()

func _run() -> void:
	while true:
		var i: int = sandbox.vmcall("pending")
		if i < 0:
			print("taskweft-acp: done")
			return
		var step: Dictionary = sandbox.vmcall("step", i)
		if not _permitted(step):
			print("taskweft-acp: step %d %s refused" % [i, step["action"]])
			sandbox.vmcall("record", i, 1)
			return
		var code := _perform(step)
		print("taskweft-acp: step %d %s exit %d" % [i, step["action"], code])
		sandbox.vmcall("record", i, code)

func _permitted(step: Dictionary) -> bool:
	if step["action"] in allow_always:
		return true
	# A headless host asks nobody; the answer is the policy. An interactive host would
	# put a confirmation dialog here.
	return step["kind"] == "read"

func _perform(step: Dictionary) -> int:
	match step["kind"]:
		"terminal":
			var output := []
			var args: Array = step["args"]
			return OS.execute(step["command"], PackedStringArray(args), output, true)
		"read":
			return 0 if FileAccess.file_exists(workspace.path_join(step["path"])) else 1
		"write":
			var f := FileAccess.open(workspace.path_join(step["path"]), FileAccess.WRITE)
			if f == null:
				return 1
			f.store_string(step.get("content", ""))
			return 0
	return 1
