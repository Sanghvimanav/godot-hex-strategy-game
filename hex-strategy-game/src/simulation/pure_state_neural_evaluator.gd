extends RefCounted
class_name PureStateNeuralEvaluator
## Experimental neural leaf evaluator for pure-state search.
##
## The model remains opt-in. A persistent Python subprocess hosts the tiny PyTorch
## value network so search can score many leaves without reloading the checkpoint
## for every simulation. Any runtime/configuration failure fails closed; callers
## must never silently fall back to the handwritten evaluator.

const PureStateEvaluator = preload("res://src/simulation/pure_state_evaluator.gd")

const DEFAULT_CHECKPOINT_PATH := "res://models/objective_aware_candidate_v1.pt"
const DEFAULT_RUNTIME_SCRIPT_PATH := "res://tools/neural_value_runtime.py"
const DEFAULT_PYTHON_EXECUTABLE := "python3"
const MODEL_VALUE_SCALE := 1000.0

static var _stdio: FileAccess = null
static var _stderr: FileAccess = null
static var _pid := -1
static var _runtime_key := ""
static var _last_error := ""


static func evaluate_breakdown(
	game_state: Dictionary,
	group_name: String,
	opponent_group_name: String,
	settings: Dictionary = {}
) -> Dictionary:
	var exact := PureStateEvaluator.evaluate_breakdown(game_state, group_name)
	if not bool(exact.get("valid", false)):
		return _invalid("invalid_game_state")
	if group_name.is_empty() or opponent_group_name.is_empty() or group_name == opponent_group_name:
		return _invalid("invalid_groups")

	var checkpoint_path := str(settings.get("checkpoint_path", ""))
	if checkpoint_path.is_empty():
		return _invalid("neural_checkpoint_required")
	var python_executable := str(settings.get("python_executable", DEFAULT_PYTHON_EXECUTABLE))
	var runtime_script_path := str(settings.get("runtime_script_path", DEFAULT_RUNTIME_SCRIPT_PATH))
	if not _ensure_runtime(checkpoint_path, python_executable, runtime_script_path):
		return _invalid(_last_error)

	var terminal_component := float(exact.get("terminal", 0.0))
	var request := {
		"state": game_state,
		"perspective_group": group_name,
		"opponent_group": opponent_group_name,
		"turn_index": int(settings.get("turn_index", game_state.get("turn_index", 0))),
		"terminal": not is_zero_approx(terminal_component),
	}
	var response := _request_value(request)
	if not bool(response.get("ok", false)):
		return _invalid(str(response.get("error", "neural_runtime_request_failed")))

	var model_value := clampf(float(response.get("value", 0.0)), -1.0, 1.0)
	var model_component := model_value * MODEL_VALUE_SCALE
	return {
		"valid": true,
		"evaluator": "neural",
		"total": terminal_component + model_component,
		"terminal": terminal_component,
		"model_value": model_value,
		"model_component": model_component,
		"checkpoint_path": checkpoint_path,
	}


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


static func last_error() -> String:
	return _last_error


static func _ensure_runtime(
	checkpoint_path: String,
	python_executable: String,
	runtime_script_path: String
) -> bool:
	var checkpoint_abs := _globalize(checkpoint_path)
	var runtime_abs := _globalize(runtime_script_path)
	var key := "%s|%s|%s" % [python_executable, runtime_abs, checkpoint_abs]
	if _stdio != null and _pid > 0 and _runtime_key == key and OS.is_process_running(_pid):
		return true

	shutdown()
	_last_error = ""
	if not FileAccess.file_exists(checkpoint_abs):
		_last_error = "neural_checkpoint_not_found:%s" % checkpoint_path
		return false
	if not FileAccess.file_exists(runtime_abs):
		_last_error = "neural_runtime_script_not_found:%s" % runtime_script_path
		return false

	var process := OS.execute_with_pipe(
		python_executable,
		PackedStringArray(["-u", runtime_abs, "--checkpoint", checkpoint_abs]),
		true
	)
	if process.is_empty():
		_last_error = "neural_runtime_start_failed"
		return false
	var stdio_variant = process.get("stdio")
	var stderr_variant = process.get("stderr")
	if not (stdio_variant is FileAccess):
		_last_error = "neural_runtime_missing_stdio"
		return false
	_stdio = stdio_variant as FileAccess
	if stderr_variant is FileAccess:
		_stderr = stderr_variant as FileAccess
	_pid = int(process.get("pid", -1))
	_runtime_key = key

	var ready_line := _stdio.get_line()
	var ready_variant = JSON.parse_string(ready_line)
	if not (ready_variant is Dictionary) or not bool((ready_variant as Dictionary).get("ready", false)):
		var error := "neural_runtime_not_ready"
		if ready_variant is Dictionary:
			error = str((ready_variant as Dictionary).get("error", error))
		_last_error = error
		shutdown()
		return false
	return true


static func _request_value(request: Dictionary) -> Dictionary:
	if _stdio == null or _pid <= 0 or not OS.is_process_running(_pid):
		_last_error = "neural_runtime_not_running"
		shutdown()
		return {"ok": false, "error": _last_error}
	_stdio.store_line(JSON.stringify(request))
	_stdio.flush()
	var line := _stdio.get_line()
	var parsed = JSON.parse_string(line)
	if not (parsed is Dictionary):
		_last_error = "neural_runtime_invalid_response"
		shutdown()
		return {"ok": false, "error": _last_error}
	var response: Dictionary = parsed
	if not bool(response.get("ok", false)):
		_last_error = str(response.get("error", "neural_runtime_request_failed"))
	return response


static func _globalize(path: String) -> String:
	if path.begins_with("res://") or path.begins_with("user://"):
		return ProjectSettings.globalize_path(path)
	if path.is_absolute_path():
		return path
	return ProjectSettings.globalize_path("res://" + path)


static func _invalid(error: String) -> Dictionary:
	return {
		"valid": false,
		"evaluator": "neural",
		"error": error,
		"total": 0.0,
		"terminal": 0.0,
		"model_value": 0.0,
		"model_component": 0.0,
	}
