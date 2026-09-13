extends RefCounted
class_name PureStateJointPolicy
## Optional autoregressive joint-plan proposal client.
##
## Uses the same persistent Python runtime as the neural value evaluator but owns a
## separate process so proposal generation cannot interfere with batched leaf
## evaluation. Old checkpoints fail closed with `unsupported=true` and callers can
## fall back to the heuristic proposal generator.

const DEFAULT_RUNTIME_SCRIPT_PATH := "res://tools/neural_value_runtime.py"
const DEFAULT_PYTHON_EXECUTABLE := "python3"

static var _stdio: FileAccess = null
static var _stderr: FileAccess = null
static var _pid := -1
static var _runtime_key := ""
static var _available := false
static var _last_error := ""


static func score_actions(
	game_state: Dictionary,
	group_name: String,
	opponent_group_name: String,
	prefix_actions: Array,
	candidate_actions: Array,
	settings: Dictionary = {}
) -> Dictionary:
	if candidate_actions.is_empty():
		return {"ok": true, "scores": [], "candidate_count": 0}
	var checkpoint_path := str(settings.get("checkpoint_path", ""))
	if checkpoint_path.is_empty():
		return {"ok": false, "unsupported": true, "error": "joint_policy_checkpoint_required"}
	var python_executable := str(settings.get("python_executable", DEFAULT_PYTHON_EXECUTABLE))
	var runtime_script_path := str(settings.get("runtime_script_path", DEFAULT_RUNTIME_SCRIPT_PATH))
	if not _ensure_runtime(checkpoint_path, python_executable, runtime_script_path):
		return {"ok": false, "unsupported": true, "error": _last_error}
	if not _available:
		return {"ok": false, "unsupported": true, "error": "joint_plan_policy_unavailable"}

	var response := _request({
		"op": "score_joint_actions",
		"state": game_state,
		"perspective_group": group_name,
		"opponent_group": opponent_group_name,
		"turn_index": int(game_state.get("turn_index", 0)),
		"prefix_actions": prefix_actions,
		"candidate_actions": candidate_actions,
	})
	if not bool(response.get("ok", false)):
		_last_error = str(response.get("error", "joint_policy_request_failed"))
	return response


static func is_available() -> bool:
	return _available


static func last_error() -> String:
	return _last_error


static func shutdown() -> void:
	if _stdio != null:
		_stdio.close()
	_stdio = null
	if _stderr != null:
		_stderr.close()
	_stderr = null
	if _pid > 0 and OS.is_process_running(_pid):
		OS.kill(_pid)
	_pid = -1
	_runtime_key = ""
	_available = false


static func _ensure_runtime(checkpoint_path: String, python_executable: String, runtime_script_path: String) -> bool:
	var checkpoint_abs := _globalize(checkpoint_path)
	var runtime_abs := _globalize(runtime_script_path)
	var key := "%s|%s|%s" % [python_executable, runtime_abs, checkpoint_abs]
	if _stdio != null and _pid > 0 and _runtime_key == key and OS.is_process_running(_pid):
		return true
	shutdown()
	_last_error = ""
	if not FileAccess.file_exists(checkpoint_abs):
		_last_error = "joint_policy_checkpoint_not_found:%s" % checkpoint_path
		return false
	if not FileAccess.file_exists(runtime_abs):
		_last_error = "joint_policy_runtime_not_found:%s" % runtime_script_path
		return false
	var process := OS.execute_with_pipe(
		python_executable,
		PackedStringArray(["-u", runtime_abs, "--checkpoint", checkpoint_abs]),
		true
	)
	if process.is_empty() or not (process.get("stdio") is FileAccess):
		_last_error = "joint_policy_runtime_start_failed"
		return false
	_stdio = process.get("stdio") as FileAccess
	if process.get("stderr") is FileAccess:
		_stderr = process.get("stderr") as FileAccess
	_pid = int(process.get("pid", -1))
	_runtime_key = key
	var ready_variant = JSON.parse_string(_stdio.get_line())
	if not (ready_variant is Dictionary) or not bool((ready_variant as Dictionary).get("ready", false)):
		_last_error = "joint_policy_runtime_not_ready"
		if ready_variant is Dictionary:
			_last_error = str((ready_variant as Dictionary).get("error", _last_error))
		shutdown()
		return false
	_available = bool((ready_variant as Dictionary).get("joint_plan_policy", false))
	return true


static func _request(payload: Dictionary) -> Dictionary:
	if _stdio == null or _pid <= 0 or not OS.is_process_running(_pid):
		return {"ok": false, "error": "joint_policy_runtime_not_running"}
	_stdio.store_line(JSON.stringify(payload))
	_stdio.flush()
	var parsed = JSON.parse_string(_stdio.get_line())
	if not (parsed is Dictionary):
		shutdown()
		return {"ok": false, "error": "joint_policy_invalid_response"}
	return parsed as Dictionary


static func _globalize(path: String) -> String:
	if path.begins_with("res://") or path.begins_with("user://"):
		return ProjectSettings.globalize_path(path)
	if path.is_absolute_path():
		return path
	return ProjectSettings.globalize_path("res://" + path)
