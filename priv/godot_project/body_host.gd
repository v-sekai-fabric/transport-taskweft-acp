# The body host (RFD 2237): one scan per frame. The guest is a SafeGDScript scan
# controller compiled by taskweft-fbd-compiler (`emit-scan`), attached to a node so
# it runs in its own sandbox. Each frame the host builds the input dictionary from the
# gamepad and the trackers (or a recorded trace when headless), calls the guest's
# `tick`, and applies the outputs: the motion command to motion-bricks.cpp through
# its demo server, everything to stdout as one `tick` line for the session log.
# Nothing else is computed here.
#
#   godot --headless --path <project with the sandbox addon> --script body_host.gd -- \
#     --controller res://plans/body.sgd [--trace trace.json] [--motion http://127.0.0.1:8080]
extends SceneTree

var guest: Node
var trace: Array = []
var trace_dt: float = 1.0 / 60.0
var tick_index: int = 0
var session: String = ""
var http: HTTPRequest
var pending_request := false
var motion_server := ""
var style_names := PackedStringArray(["idle", "walk", "run", "wave"])
var seed := 7
var done := false


func _initialize() -> void:
	var args := _args()
	var controller_path: String = args.get("controller", "res://plans/body.sgd")
	motion_server = args.get("motion", "")
	var program := load(controller_path)
	if program == null:
		push_error("body host: no controller at %s" % controller_path)
		done = true
		return
	if program.has_method("get_compile_error") and program.get_compile_error() != "":
		push_error("body host: controller does not compile: " + program.get_compile_error())
		done = true
		return
	guest = Node.new()
	root.add_child(guest)
	guest.set_script(program)
	if not guest.has_method("tick"):
		push_error("body host: the controller publishes no tick")
		done = true
		return
	var trace_path: String = args.get("trace", "")
	if trace_path != "":
		var parsed: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(trace_path))
		trace = parsed.get("ticks", [])
		trace_dt = float(parsed.get("dt", trace_dt))
	if motion_server != "":
		http = HTTPRequest.new()
		root.add_child(http)
		http.request_completed.connect(_on_motion_reply)
		_open_session()
	print("body host: controller %s, %s" % [controller_path, "trace of %d tick(s)" % trace.size() if not trace.is_empty() else "live inputs"])


func _process(delta: float) -> bool:
	if done:
		OS.kill(OS.get_process_id())
		return true
	var inputs: Dictionary
	var dt := delta
	if not trace.is_empty():
		if tick_index >= trace.size():
			print("trace done: %d tick(s)" % tick_index)
			done = true
			return false
		inputs = trace[tick_index]
		dt = float(inputs.get("dt", trace_dt))
	else:
		inputs = _live_inputs()
	var outputs: Dictionary = guest.call("tick", inputs, dt)
	print("tick ", JSON.stringify({"i": tick_index, "dt": dt, "in": inputs, "out": outputs}))
	if outputs.has("_fault"):
		push_error("body host: controller fault: " + str(outputs["_fault"]))
	else:
		_apply(outputs)
	tick_index += 1
	return false


# Joypad 0 under the names the controller declares; trackers from XRServer when
# one is present. A tracker that is absent reads as not ok, never as zeros.
func _live_inputs() -> Dictionary:
	var inputs := {
		"pad0_lx": Input.get_joy_axis(0, JOY_AXIS_LEFT_X),
		"pad0_ly": Input.get_joy_axis(0, JOY_AXIS_LEFT_Y),
		"pad0_rx": Input.get_joy_axis(0, JOY_AXIS_RIGHT_X),
		"pad0_ry": Input.get_joy_axis(0, JOY_AXIS_RIGHT_Y),
		"pad0_a": Input.is_joy_button_pressed(0, JOY_BUTTON_A),
		"pad0_b": Input.is_joy_button_pressed(0, JOY_BUTTON_B),
		"pad0_x": Input.is_joy_button_pressed(0, JOY_BUTTON_X),
		"pad0_y": Input.is_joy_button_pressed(0, JOY_BUTTON_Y),
		"pad0_ok": Input.get_connected_joypads().has(0),
	}
	var trackers := XRServer.get_trackers(XRServer.TRACKER_BODY | XRServer.TRACKER_CONTROLLER)
	var i := 0
	for name in trackers.keys():
		var t: XRPositionalTracker = trackers[name]
		var pose := t.get_pose("default")
		var ok := pose != null and pose.has_tracking_data
		inputs["mocap%d_ok" % i] = ok
		if ok:
			var p := pose.transform.origin
			inputs["mocap%d_px" % i] = p.x
			inputs["mocap%d_py" % i] = p.y
			inputs["mocap%d_pz" % i] = p.z
		i += 1
	return inputs


func _apply(outputs: Dictionary) -> void:
	if http == null or session == "" or pending_request:
		return
	var style_index := int(outputs.get("style", 0))
	var style := style_names[clampi(style_index, 0, style_names.size() - 1)]
	var command := {
		"session": session,
		"style": style,
		"move": [float(outputs.get("move_x", 0.0)), float(outputs.get("move_z", 0.0))],
		"facing": [float(outputs.get("face_x", 0.0)), float(outputs.get("face_z", 0.0))],
		"speed": float(outputs.get("speed", 0.0)),
		"seed": seed,
		"advance": 1,
	}
	pending_request = true
	http.request(motion_server + "/api/plan", ["Content-Type: application/json"], HTTPClient.METHOD_POST, JSON.stringify(command))


func _open_session() -> void:
	pending_request = true
	http.request(motion_server + "/api/session", ["Content-Type: application/json"], HTTPClient.METHOD_POST, JSON.stringify({"style": style_names[0]}))


func _on_motion_reply(_result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	pending_request = false
	if code != 200:
		push_error("motion server answered %d" % code)
		return
	var reply = JSON.parse_string(body.get_string_from_utf8())
	if reply is Dictionary and session == "" and reply.has("session"):
		session = str(reply["session"])
		print("motion session ", session)


func _args() -> Dictionary:
	var out := {}
	var argv := OS.get_cmdline_user_args()
	var i := 0
	while i < argv.size():
		var a: String = argv[i]
		if a.begins_with("--") and i + 1 < argv.size():
			out[a.substr(2)] = argv[i + 1]
			i += 2
		else:
			i += 1
	return out
