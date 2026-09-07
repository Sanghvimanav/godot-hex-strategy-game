extends Node
## Post-process self-play traces into full fast-search decision matrices.
##
## V1 intentionally targets the 2x2 "fast" budget. It reruns only those decisions
## after the game is over, retaining both own candidates, both modeled opponent
## responses, and every simulated leaf state without changing the played game.

const PureStateSearchDecisionData = preload("res://src/simulation/pure_state_search_decision_data.gd")

const MANIFEST_SCHEMA_VERSION := 1


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	var args := _parse_cmdline_kv()
	var out_dir := str(args.get("out", "user://self_play_dataset"))
	var abs_out := ProjectSettings.globalize_path(out_dir)
	var traces_path := abs_out.path_join("traces.jsonl")
	var decisions_path := abs_out.path_join("search_decisions.jsonl")
	var manifest_path := abs_out.path_join("search_decisions_manifest.json")

	# _read_jsonl can return either an Array or null on failure. Keep that
	# explicit so warnings-as-errors does not reject Variant type inference.
	var traces: Variant = _read_jsonl(traces_path)
	if traces == null:
		get_tree().quit(1)
		return

	var rows: Array = []
	var traces_considered := 0
	var fast_traces := 0
	var turns_considered := 0
	var failed_decisions := 0
	var selected_candidate_missing := 0
	var complete_matrices := 0
	var incomplete_matrices := 0

	for trace_variant in traces:
		if not (trace_variant is Dictionary):
			continue
		var trace: Dictionary = trace_variant
		traces_considered += 1
		var source_variant = trace.get("source", {})
		if not (source_variant is Dictionary):
			continue
		var source: Dictionary = source_variant
		var own_max_plans := int(source.get("own_max_plans", 0))
		var opponent_max_plans := int(source.get("opponent_max_plans", 0))
		if own_max_plans != 2 or opponent_max_plans != 2:
			continue
		fast_traces += 1
		var max_actions_per_unit := int(source.get("max_actions_per_unit", 0))
		var groups_variant = trace.get("groups", [])
		if not (groups_variant is Array) or (groups_variant as Array).size() != 2:
			push_error("Search-decision trace has invalid groups: %s" % str(trace.get("game_id", "")))
			get_tree().quit(1)
			return
		var groups: Array = groups_variant
		var group_a := str(groups[0])
		var group_b := str(groups[1])
		var game_id := str(trace.get("game_id", ""))
		var game_status := str(trace.get("status", ""))
		var winner := str(trace.get("winner", ""))
		var termination_reason := str(trace.get("termination_reason", ""))
		var turns_played := int(trace.get("turns_played", 0))

		for turn_variant in trace.get("turns", []):
			if not (turn_variant is Dictionary):
				continue
			var turn: Dictionary = turn_variant
			var state_variant = turn.get("state_before", {})
			if not (state_variant is Dictionary) or (state_variant as Dictionary).is_empty():
				continue
			var state_before: Dictionary = state_variant
			var turn_index := int(turn.get("turn", 0))
			if turn_index <= 0:
				continue
			turns_considered += 1

			for pair_variant in [[group_a, group_b], [group_b, group_a]]:
				var pair: Array = pair_variant
				var perspective_group := str(pair[0])
				var opponent_group := str(pair[1])
				var action_key := perspective_group + "_actions"
				# Search-failure traces may contain a final attempted turn without a
				# completed selected action. Preserve completed decisions only.
				if not turn.has(action_key):
					continue
				var selected_variant = turn.get(action_key, [])
				if not (selected_variant is Array):
					continue
				var selected_actions: Array = selected_variant
				var labeled_outcome := game_status == "terminal"
				var perspective_outcome := 0.0
				if labeled_outcome and not winner.is_empty():
					perspective_outcome = 1.0 if winner == perspective_group else -1.0
				var game_outcome := {
					"labeled": labeled_outcome,
					"status": game_status,
					"winner": winner,
					"perspective_outcome": perspective_outcome,
					"termination_reason": termination_reason,
					"turns_played": turns_played,
				}
				var row := PureStateSearchDecisionData.capture_decision(
					state_before,
					perspective_group,
					opponent_group,
					selected_actions,
					max_actions_per_unit,
					own_max_plans,
					opponent_max_plans,
					game_id,
					turn_index,
					game_outcome,
					source
				)
				if not bool(row.get("valid", false)):
					failed_decisions += 1
					push_error("Search-decision capture failed game=%s turn=%d side=%s error=%s" % [
						game_id,
						turn_index,
						perspective_group,
						str(row.get("error", "unknown")),
					])
					continue
				if int(row.get("selected_candidate_index", -1)) < 0:
					selected_candidate_missing += 1
				if bool(row.get("complete_requested_matrix", false)):
					complete_matrices += 1
				else:
					incomplete_matrices += 1
				rows.append(row)

	var manifest := {
		"manifest_schema_version": MANIFEST_SCHEMA_VERSION,
		"search_decision_schema_version": PureStateSearchDecisionData.SCHEMA_VERSION,
		"candidate_generation_contract_version": PureStateSearchDecisionData.CANDIDATE_GENERATION_CONTRACT_VERSION,
		"budget": "2x2",
		"source_trace_file": "traces.jsonl",
		"decision_file": "search_decisions.jsonl",
		"traces_considered": traces_considered,
		"fast_traces": fast_traces,
		"turns_considered": turns_considered,
		"decision_count": rows.size(),
		"complete_matrix_count": complete_matrices,
		"incomplete_matrix_count": incomplete_matrices,
		"failed_decision_count": failed_decisions,
		"selected_candidate_missing_count": selected_candidate_missing,
	}

	var write_ok := _write_text(decisions_path, _to_jsonl(rows))
	write_ok = _write_text(manifest_path, JSON.stringify(manifest, "  ") + "\n") and write_ok
	print("[search-decisions] wrote %s" % decisions_path)
	print("[search-decisions] wrote %s" % manifest_path)
	print("[search-decisions] traces=%d fast=%d decisions=%d complete=%d incomplete=%d failed=%d selected_missing=%d" % [
		traces_considered,
		fast_traces,
		rows.size(),
		complete_matrices,
		incomplete_matrices,
		failed_decisions,
		selected_candidate_missing,
	])

	# Misaligned selected actions would mean this post-processor no longer mirrors
	# the actual search candidate source. Fail closed so training never consumes it.
	var valid := failed_decisions == 0 and selected_candidate_missing == 0
	get_tree().quit(0 if write_ok and valid else 1)


func _read_jsonl(path: String) -> Variant:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_error("Cannot open self-play traces: %s" % path)
		return null
	var rows: Array = []
	while not file.eof_reached():
		var line := file.get_line().strip_edges()
		if line.is_empty():
			continue
		var parsed = JSON.parse_string(line)
		if not (parsed is Dictionary):
			push_error("Invalid JSONL row in %s" % path)
			file.close()
			return null
		rows.append(parsed)
	file.close()
	return rows


func _to_jsonl(rows: Array) -> String:
	var lines: Array[String] = []
	for row_variant in rows:
		if row_variant is Dictionary:
			lines.append(JSON.stringify(row_variant))
	if lines.is_empty():
		return ""
	return "\n".join(lines) + "\n"


func _write_text(path: String, text: String) -> bool:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_error("Cannot write %s" % path)
		return false
	file.store_string(text)
	file.close()
	return true


func _parse_cmdline_kv() -> Dictionary:
	var result: Dictionary = {}
	var raw: PackedStringArray = OS.get_cmdline_user_args()
	if raw.is_empty():
		raw = OS.get_cmdline_args()
	var i := 0
	while i < raw.size():
		var arg := str(raw[i]).strip_edges()
		if arg.is_empty():
			i += 1
			continue
		if arg.begins_with("--"):
			arg = arg.substr(2)
		if arg.contains("="):
			var parts := arg.split("=", true, 1)
			result[parts[0]] = parts[1]
		else:
			var next_value := ""
			if i + 1 < raw.size() and not str(raw[i + 1]).begins_with("-"):
				next_value = str(raw[i + 1]).strip_edges()
				i += 1
			result[arg] = next_value if not next_value.is_empty() else "true"
		i += 1
	return result
