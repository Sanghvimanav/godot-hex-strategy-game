extends RefCounted
class_name LlmPlanningPayloadLog
## Writes each planning API user payload (JSON snapshot) under user://llm_planning_logs/ when enabled in LlmAiSettings.

const LOG_DIR := "user://llm_planning_logs"


static func write_turn_if_enabled(turn: int, snapshot: Dictionary, settings: LlmAiSettings) -> void:
	if not settings.log_planning_payloads:
		return
	var da := DirAccess.open("user://")
	if da == null:
		push_warning("LlmPlanningPayloadLog: cannot open user://")
		return
	da.make_dir_recursive("llm_planning_logs")
	var stamp: int = Time.get_ticks_msec()
	var fname := "planning_turn_%d_%d.json" % [turn, stamp]
	var path: String = LOG_DIR.path_join(fname)
	var wrap: Dictionary = {
		"turn": turn,
		"logged_ticks_msec": stamp,
		"snapshot": snapshot,
	}
	var text: String = JSON.stringify(wrap, "\t")
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_warning("LlmPlanningPayloadLog: cannot write %s (err %d)" % [path, FileAccess.get_open_error()])
		return
	f.store_string(text)
	f.close()
	if OS.is_debug_build():
		print("[LLM] planning payload logged: %s" % ProjectSettings.globalize_path(path))
