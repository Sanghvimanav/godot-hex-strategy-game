extends CanvasLayer

const LEADERBOARD_PATH := "res://tools/evals/leaderboard.jsonl"
const RUNS_ROOT := "res://tools/evals/runs"
const SELF_EVOLVE_ROOT := "res://tools/evals/self_evolve"

@onready var back_btn: Button = $center/panel/margin/vbox/top_row/back_btn
@onready var refresh_btn: Button = $center/panel/margin/vbox/top_row/refresh_btn
@onready var open_runs_btn: Button = $center/panel/margin/vbox/top_row/open_runs_btn
@onready var status_label: Label = $center/panel/margin/vbox/status_label
@onready var leaderboard_tree: Tree = $center/panel/margin/vbox/content_split/left_col/list_card/list_margin/leaderboard_tree
@onready var summary_title: Label = $center/panel/margin/vbox/content_split/right_col/summary_card/summary_margin/summary_vbox/summary_title
@onready var summary_text: TextEdit = $center/panel/margin/vbox/content_split/right_col/summary_card/summary_margin/summary_vbox/summary_scroll/summary_text

var _rows: Array[Dictionary] = []
const _COL_RUN_ID := 0
const _COL_MODE := 1
const _COL_MODEL := 2
const _COL_THINKING := 3
const _COL_PASS_RATE := 4
const _COL_SCORE := 5
const _COL_AVG_SPEED := 6
const _COL_EST_COST := 7
const _COL_CREATED := 8


func _ready() -> void:
	if back_btn:
		back_btn.pressed.connect(_on_back_pressed)
	if refresh_btn:
		refresh_btn.pressed.connect(_reload_all)
	if open_runs_btn:
		open_runs_btn.pressed.connect(_on_open_runs_pressed)
	if leaderboard_tree:
		_setup_tree_columns()
		leaderboard_tree.item_selected.connect(_on_row_selected)
	_reload_all()


func _on_back_pressed() -> void:
	get_tree().change_scene_to_file("res://src/battle/scenario_picker.tscn")


func _on_open_runs_pressed() -> void:
	OS.shell_open(ProjectSettings.globalize_path(RUNS_ROOT))


func _reload_all() -> void:
	_rows = _load_leaderboard_rows()
	_rebuild_list()
	if _rows.is_empty():
		_set_summary_text("No leaderboard rows found.\nRun: python3 tools/evals/run_eval_suite.py ...")
		status_label.text = "No runs yet."
	else:
		status_label.text = "Loaded %d run(s)." % _rows.size()
		var root: TreeItem = leaderboard_tree.get_root()
		if root and root.get_child_count() > 0:
			var first: TreeItem = root.get_child(0)
			if first:
				first.select(_COL_RUN_ID)
				_show_summary_for_run_id(str(first.get_metadata(_COL_RUN_ID)))


func _load_leaderboard_rows() -> Array[Dictionary]:
	var rows: Array[Dictionary] = []
	if not FileAccess.file_exists(LEADERBOARD_PATH):
		return rows

	var f: FileAccess = FileAccess.open(LEADERBOARD_PATH, FileAccess.READ)
	if f == null:
		return rows

	while not f.eof_reached():
		var line := f.get_line().strip_edges()
		if line.is_empty():
			continue
		var p: Variant = JSON.parse_string(line)
		if typeof(p) == TYPE_DICTIONARY:
			var row: Dictionary = p as Dictionary
			var mode := str(row.get("mode", "")).strip_edges().to_lower()
			if mode == "snapshot":
				continue
			rows.append(row)
	rows.reverse() # newest first
	return rows


func _setup_tree_columns() -> void:
	if leaderboard_tree == null:
		return
	leaderboard_tree.columns = 9
	leaderboard_tree.column_titles_visible = true
	leaderboard_tree.hide_root = true
	leaderboard_tree.set_column_title(_COL_RUN_ID, "Run ID")
	leaderboard_tree.set_column_title(_COL_MODE, "Mode")
	leaderboard_tree.set_column_title(_COL_MODEL, "Model")
	leaderboard_tree.set_column_title(_COL_THINKING, "Thinking")
	leaderboard_tree.set_column_title(_COL_PASS_RATE, "Pass %")
	leaderboard_tree.set_column_title(_COL_SCORE, "Score")
	leaderboard_tree.set_column_title(_COL_AVG_SPEED, "Avg Speed")
	leaderboard_tree.set_column_title(_COL_EST_COST, "Est. Cost / Turn")
	leaderboard_tree.set_column_title(_COL_CREATED, "Created")
	leaderboard_tree.set_column_expand(_COL_RUN_ID, true)
	leaderboard_tree.set_column_expand(_COL_MODE, false)
	leaderboard_tree.set_column_expand(_COL_MODEL, false)
	leaderboard_tree.set_column_expand(_COL_THINKING, false)
	leaderboard_tree.set_column_expand(_COL_PASS_RATE, false)
	leaderboard_tree.set_column_expand(_COL_SCORE, false)
	leaderboard_tree.set_column_expand(_COL_AVG_SPEED, false)
	leaderboard_tree.set_column_expand(_COL_EST_COST, false)
	leaderboard_tree.set_column_expand(_COL_CREATED, false)
	leaderboard_tree.set_column_custom_minimum_width(_COL_MODEL, 120)
	leaderboard_tree.set_column_custom_minimum_width(_COL_CREATED, 220)


func _rebuild_list() -> void:
	if leaderboard_tree == null:
		return
	leaderboard_tree.clear()
	var root: TreeItem = leaderboard_tree.create_item()
	for row in _rows:
		var run_id := str(row.get("run_id", ""))
		var mode := str(row.get("mode", ""))
		var created := str(row.get("created_at", ""))
		var pass_rate := float(row.get("pass_rate", 0.0)) * 100.0
		var score := float(row.get("avg_final_score", 0.0))
		var avg_speed := float(row.get("avg_speed_on_pass", 0.0))
		var thinking := str(row.get("thinking_level", ""))
		if thinking.is_empty():
			thinking = "-"
		var model := str(row.get("model_version", ""))
		if model.is_empty():
			model = "(default)"
		var est_cost_usd := float(row.get("estimated_cost_usd_per_eval_turn", 0.0))

		var item: TreeItem = leaderboard_tree.create_item(root)
		item.set_text(_COL_RUN_ID, run_id)
		item.set_text(_COL_MODE, mode)
		item.set_text(_COL_MODEL, model)
		item.set_text(_COL_THINKING, thinking)
		item.set_text(_COL_PASS_RATE, "%.1f" % pass_rate)
		item.set_text(_COL_SCORE, "%.3f" % score)
		item.set_text(_COL_AVG_SPEED, "%.3f" % avg_speed)
		item.set_text(_COL_EST_COST, "$%.4f" % est_cost_usd)
		item.set_text(_COL_CREATED, created)
		item.set_metadata(_COL_RUN_ID, run_id)


func _on_row_selected() -> void:
	if leaderboard_tree == null:
		return
	var selected: TreeItem = leaderboard_tree.get_selected()
	if selected == null:
		return
	_show_summary_for_run_id(str(selected.get_metadata(_COL_RUN_ID)))


func _show_summary_for_run_id(run_id: String) -> void:
	if run_id.is_empty():
		return
	summary_title.text = "Run Summary: %s" % run_id

	var summary_path := "%s/%s/summary.json" % [RUNS_ROOT, run_id]
	var summary_dict := _read_json_file(summary_path)
	if summary_dict.is_empty():
		var fallback_user_path := "user://tools/evals/runs/%s/summary.json" % run_id
		var fallback_summary := _read_json_file(fallback_user_path)
		if fallback_summary.is_empty():
			_set_summary_text(
				"Summary not found for run '%s'.\nChecked:\n- %s\n- %s" % [run_id, summary_path, fallback_user_path]
			)
			return
		_set_summary_text(_build_summary_with_prompt_text(run_id, fallback_summary))
		return
	_set_summary_text(_build_summary_with_prompt_text(run_id, summary_dict))


func _build_summary_with_prompt_text(run_id: String, summary_dict: Dictionary) -> String:
	var out := JSON.stringify(summary_dict, "  ")
	var llm_input_info := _extract_llm_input_example_for_run(run_id)
	if llm_input_info.is_empty():
		return out
	var mode_label := str(llm_input_info.get("mode_label", "single-call"))
	var source_file := str(llm_input_info.get("source_file", ""))
	var system_prompt := str(llm_input_info.get("system_prompt", ""))
	var payload_preview := str(llm_input_info.get("payload_preview", ""))
	out += "\n\n----- Example LLM Input (%s) -----\n" % mode_label
	if not source_file.is_empty():
		out += "Source case: %s\n\n" % source_file
	out += "[System Prompt]\n%s\n\n" % system_prompt
	out += "[Payload Preview]\n%s" % _format_payload_preview(payload_preview)
	out += _build_snapshot_suggestions_text(run_id)
	return out


func _extract_llm_input_example_for_run(run_id: String) -> Dictionary:
	var case_dirs: Array[String] = [
		"%s/%s/cases" % [RUNS_ROOT, run_id],
		"user://tools/evals/runs/%s/cases" % run_id,
	]
	for cases_dir in case_dirs:
		var dir := DirAccess.open(cases_dir)
		if dir == null:
			continue
		dir.list_dir_begin()
		var name := dir.get_next()
		while name != "":
			if not dir.current_is_dir() and name.ends_with(".json"):
				var case_path := "%s/%s" % [cases_dir, name]
				var case_dict := _read_json_file(case_path)
				var llm: Variant = case_dict.get("llm", {})
				if typeof(llm) == TYPE_DICTIONARY:
					var prompt_debug: Variant = (llm as Dictionary).get("prompt_debug", {})
					if typeof(prompt_debug) == TYPE_DICTIONARY:
						var pd := prompt_debug as Dictionary
						var system_prompt := str(pd.get("system_prompt", "")).strip_edges()
						var input_preview := str(pd.get("input_preview", "")).strip_edges()
						if not system_prompt.is_empty():
							dir.list_dir_end()
							return {
								"mode_label": "single-call",
								"system_prompt": system_prompt,
								"payload_preview": input_preview,
								"source_file": name
							}
						var action_prompt := str(pd.get("action_prompt", "")).strip_edges()
						var action_input_preview := str(pd.get("action_input_preview", "")).strip_edges()
						if not action_prompt.is_empty():
							dir.list_dir_end()
							return {
								"mode_label": "two-call (action pass)",
								"system_prompt": action_prompt,
								"payload_preview": action_input_preview,
								"source_file": name
							}
						var prediction_prompt := str(pd.get("prediction_prompt", "")).strip_edges()
						var prediction_input_preview := str(pd.get("prediction_input_preview", "")).strip_edges()
						if not prediction_prompt.is_empty():
							dir.list_dir_end()
							return {
								"mode_label": "two-call (prediction pass)",
								"system_prompt": prediction_prompt,
								"payload_preview": prediction_input_preview,
								"source_file": name
							}
			name = dir.get_next()
		dir.list_dir_end()
	return {}


func _build_snapshot_suggestions_text(run_id: String) -> String:
	var session_id := _self_evolve_session_id_from_run_id(run_id)
	if session_id.is_empty():
		return ""
	var suggestions_path := "%s/%s/snapshot_field_suggestions.json" % [SELF_EVOLVE_ROOT, session_id]
	var suggestions_doc := _read_json_file(suggestions_path)
	if suggestions_doc.is_empty():
		var fallback_user_path := "user://tools/evals/self_evolve/%s/snapshot_field_suggestions.json" % session_id
		suggestions_doc = _read_json_file(fallback_user_path)
	if suggestions_doc.is_empty():
		return ""
	var arr: Array = suggestions_doc.get("suggested_snapshot_fields_to_add", []) as Array
	if arr.is_empty():
		return ""
	var out := "\n\n----- Snapshot Field Suggestions -----\n"
	for s in arr:
		if not (s is Dictionary):
			continue
		var sd: Dictionary = s as Dictionary
		var field_name := str(sd.get("field_name", "")).strip_edges()
		var where := str(sd.get("where", "")).strip_edges()
		var why := str(sd.get("why", "")).strip_edges()
		var iter_val := str(sd.get("iter", "")).strip_edges()
		if field_name.is_empty() and where.is_empty() and why.is_empty():
			continue
		out += "- "
		if not field_name.is_empty():
			out += field_name
		else:
			out += "(unnamed)"
		if not where.is_empty():
			out += " @ %s" % where
		if not iter_val.is_empty():
			out += " [iter %s]" % iter_val
		if not why.is_empty():
			out += " — %s" % why
		out += "\n"
	return out


func _self_evolve_session_id_from_run_id(run_id: String) -> String:
	var rid := run_id.strip_edges()
	var marker := "_iter"
	var pos := rid.rfind(marker)
	if pos <= 0:
		return ""
	var suffix := rid.substr(pos + marker.length())
	if suffix.is_empty():
		return ""
	for i in range(suffix.length()):
		var ch := suffix.substr(i, 1)
		if ch < "0" or ch > "9":
			return ""
	return rid.substr(0, pos)


func _format_payload_preview(raw_payload: String) -> String:
	var txt := raw_payload.strip_edges()
	if txt.is_empty():
		return "(empty)"
	var parsed: Variant = JSON.parse_string(txt)
	if typeof(parsed) == TYPE_DICTIONARY or typeof(parsed) == TYPE_ARRAY:
		return JSON.stringify(parsed, "  ")
	return _soft_wrap_text(txt, 110)


func _soft_wrap_text(text: String, width: int = 110) -> String:
	if width <= 0:
		return text
	var lines: Array[String] = []
	var i := 0
	while i < text.length():
		var remaining: int = text.length() - i
		var take: int = mini(width, remaining)
		lines.append(text.substr(i, take))
		i += take
	return "\n".join(lines)


func _read_json_file(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var text := FileAccess.get_file_as_string(path)
	if text.strip_edges().is_empty():
		return {}
	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		return {}
	return parsed as Dictionary


func _set_summary_text(text: String) -> void:
	if summary_text:
		summary_text.text = text
