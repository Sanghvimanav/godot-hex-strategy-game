extends Node
## Post-process self-play traces into candidate x response decision matrices.
##
## Gameplay is untouched. By default this reproduces the historical fast 2x2
## recorder. Offline experiments can widen capture with
## --decision-own-max-plans / --decision-opponent-max-plans so a played 2x2 turn
## can expose extra siblings for training without paying that search cost in game.

const PureStateSearchDecisionData = preload("res://src/simulation/pure_state_search_decision_data.gd")

const MANIFEST_SCHEMA_VERSION := 2


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	var args: Dictionary = _parse_cmdline_kv()
	var out_dir: String = str(args.get("out", "user://self_play_dataset"))
	var abs_out: String = ProjectSettings.globalize_path(out_dir)
	var traces_path: String = abs_out.path_join("traces.jsonl")
	var decisions_path: String = abs_out.path_join("search_decisions.jsonl")
	var manifest_path: String = abs_out.path_join("search_decisions_manifest.json")
	var source_own_max_plans: int = maxi(1, int(args.get("decision-source-own-max-plans", 2)))
	var source_opponent_max_plans: int = maxi(1, int(args.get("decision-source-opponent-max-plans", 2)))
	var capture_own_max_plans: int = maxi(
		source_own_max_plans,
		int(args.get("decision-own-max-plans", source_own_max_plans))
	)
	var capture_opponent_max_plans: int = maxi(
		source_opponent_max_plans,
		int(args.get("decision-opponent-max-plans", source_opponent_max_plans))
	)

	var traces_variant: Variant = _read_jsonl(traces_path)
	if traces_variant == null:
		get_tree().quit(1)
		return
	var traces: Array = traces_variant as Array

	var rows: Array = []
	var traces_considered: int = 0
	var source_budget_traces: int = 0
	var turns_considered: int = 0
	var failed_decisions: int = 0
	var selected_candidate_missing: int = 0
	var selected_candidate_preserved: int = 0
	var complete_matrices: int = 0
	var incomplete_matrices: int = 0

	for trace_variant: Variant in traces:
		if not (trace_variant is Dictionary):
			continue
		var trace: Dictionary = trace_variant as Dictionary
		traces_considered += 1
		var source_variant: Variant = trace.get("source", {})
		if not (source_variant is Dictionary):
			continue
		var source: Dictionary = source_variant as Dictionary
		var played_own_max_plans: int = int(source.get("own_max_plans", 0))
		var played_opponent_max_plans: int = int(source.get("opponent_max_plans", 0))
		if played_own_max_plans != source_own_max_plans or played_opponent_max_plans != source_opponent_max_plans:
			continue
		source_budget_traces += 1
		var max_actions_per_unit: int = int(source.get("max_actions_per_unit", 0))
		var groups_variant: Variant = trace.get("groups", [])
		if not (groups_variant is Array) or (groups_variant as Array).size() != 2:
			push_error("Search-decision trace has invalid groups: %s" % str(trace.get("game_id", "")))
			get_tree().quit(1)
			return
		var groups: Array = groups_variant as Array
		var group_a: String = str(groups[0])
		var group_b: String = str(groups[1])
		var game_id: String = str(trace.get("game_id", ""))
		var game_status: String = str(trace.get("status", ""))
		var winner: String = str(trace.get("winner", ""))
		var termination_reason: String = str(trace.get("termination_reason", ""))
		var turns_played: int = int(trace.get("turns_played", 0))

		for turn_variant: Variant in trace.get("turns", []):
			if not (turn_variant is Dictionary):
				continue
			var turn: Dictionary = turn_variant as Dictionary
			var state_variant: Variant = turn.get("state_before", {})
			if not (state_variant is Dictionary) or (state_variant as Dictionary).is_empty():
				continue
			var state_before: Dictionary = state_variant as Dictionary
			var turn_index: int = int(turn.get("turn", 0))
			if turn_index <= 0:
				continue
			turns_considered += 1

			for pair_variant: Variant in [[group_a, group_b], [group_b, group_a]]:
				var pair: Array = pair_variant as Array
				var perspective_group: String = str(pair[0])
				var opponent_group: String = str(pair[1])
				var action_key: String = perspective_group + "_actions"
				if not turn.has(action_key):
					continue
				var selected_variant: Variant = turn.get(action_key, [])
				if not (selected_variant is Array):
					continue
				var selected_actions: Array = selected_variant as Array
				var labeled_outcome: bool = game_status == "terminal"
				var perspective_outcome: float = 0.0
				if labeled_outcome and not winner.is_empty():
					perspective_outcome = 1.0 if winner == perspective_group else -1.0
				var game_outcome: Dictionary = {
					"labeled": labeled_outcome,
					"status": game_status,
					"winner": winner,
					"perspective_outcome": perspective_outcome,
					"termination_reason": termination_reason,
					"turns_played": turns_played,
				}
				var capture_source: Dictionary = source.duplicate(true)
				capture_source["played_own_max_plans"] = played_own_max_plans
				capture_source["played_opponent_max_plans"] = played_opponent_max_plans
				capture_source["decision_capture_own_max_plans"] = capture_own_max_plans
				capture_source["decision_capture_opponent_max_plans"] = capture_opponent_max_plans
				var row: Dictionary = PureStateSearchDecisionData.capture_decision(
					state_before,
					perspective_group,
					opponent_group,
					selected_actions,
					max_actions_per_unit,
					capture_own_max_plans,
					capture_opponent_max_plans,
					game_id,
					turn_index,
					game_outcome,
					capture_source
				)
				if bool(row.get("valid", false)) and int(row.get("selected_candidate_index", -1)) < 0:
					row = _preserve_played_candidate_from_source_search(
						row,
						state_before,
						perspective_group,
						opponent_group,
						selected_actions,
						max_actions_per_unit,
						source_own_max_plans,
						source_opponent_max_plans,
						capture_own_max_plans,
						capture_opponent_max_plans,
						game_id,
						turn_index,
						game_outcome,
						capture_source
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
				if bool(row.get("selected_candidate_preserved", false)):
					selected_candidate_preserved += 1
				if int(row.get("selected_candidate_index", -1)) < 0:
					selected_candidate_missing += 1
				if bool(row.get("complete_requested_matrix", false)):
					complete_matrices += 1
				else:
					incomplete_matrices += 1
				rows.append(row)

	var manifest: Dictionary = {
		"manifest_schema_version": MANIFEST_SCHEMA_VERSION,
		"search_decision_schema_version": PureStateSearchDecisionData.SCHEMA_VERSION,
		"candidate_generation_contract_version": PureStateSearchDecisionData.CANDIDATE_GENERATION_CONTRACT_VERSION,
		"source_budget": "%dx%d" % [source_own_max_plans, source_opponent_max_plans],
		"capture_budget": "%dx%d" % [capture_own_max_plans, capture_opponent_max_plans],
		"source_trace_file": "traces.jsonl",
		"decision_file": "search_decisions.jsonl",
		"traces_considered": traces_considered,
		"source_budget_traces": source_budget_traces,
		"turns_considered": turns_considered,
		"decision_count": rows.size(),
		"complete_matrix_count": complete_matrices,
		"incomplete_matrix_count": incomplete_matrices,
		"failed_decision_count": failed_decisions,
		"selected_candidate_missing_count": selected_candidate_missing,
		"selected_candidate_preserved_count": selected_candidate_preserved,
	}

	var write_ok: bool = _write_text(decisions_path, _to_jsonl(rows))
	write_ok = _write_text(manifest_path, JSON.stringify(manifest, "  ") + "\n") and write_ok
	print("[search-decisions-v2] wrote %s" % decisions_path)
	print("[search-decisions-v2] wrote %s" % manifest_path)
	print("[search-decisions-v2] traces=%d source=%d decisions=%d capture=%dx%d complete=%d incomplete=%d failed=%d selected_missing=%d selected_preserved=%d" % [
		traces_considered,
		source_budget_traces,
		rows.size(),
		capture_own_max_plans,
		capture_opponent_max_plans,
		complete_matrices,
		incomplete_matrices,
		failed_decisions,
		selected_candidate_missing,
		selected_candidate_preserved,
	])
	var valid: bool = failed_decisions == 0 and selected_candidate_missing == 0
	get_tree().quit(0 if write_ok and valid else 1)


func _preserve_played_candidate_from_source_search(
	wide_row: Dictionary,
	game_state: Dictionary,
	perspective_group: String,
	opponent_group: String,
	selected_actions: Array,
	max_actions_per_unit: int,
	source_own_max_plans: int,
	source_opponent_max_plans: int,
	capture_own_max_plans: int,
	capture_opponent_max_plans: int,
	game_id: String,
	turn_index: int,
	game_outcome: Dictionary,
	capture_source: Dictionary
) -> Dictionary:
	# Only repair intentional own-side widening. A missing selected candidate at the
	# original gameplay budget still fails closed so genuine generation drift is visible.
	if capture_own_max_plans <= source_own_max_plans:
		return wide_row
	if capture_opponent_max_plans != source_opponent_max_plans:
		return wide_row

	var source_row: Dictionary = PureStateSearchDecisionData.capture_decision(
		game_state,
		perspective_group,
		opponent_group,
		selected_actions,
		max_actions_per_unit,
		source_own_max_plans,
		source_opponent_max_plans,
		game_id,
		turn_index,
		game_outcome,
		capture_source
	)
	if not bool(source_row.get("valid", false)):
		return wide_row
	var source_selected_index: int = int(source_row.get("selected_candidate_index", -1))
	if source_selected_index < 0:
		return wide_row
	var source_candidates_variant: Variant = source_row.get("candidates", [])
	var wide_candidates_variant: Variant = wide_row.get("candidates", [])
	if not (source_candidates_variant is Array) or not (wide_candidates_variant is Array):
		return wide_row
	var source_candidates: Array = source_candidates_variant as Array
	var wide_candidates: Array = wide_candidates_variant as Array
	if source_selected_index >= source_candidates.size() or wide_candidates.is_empty():
		return wide_row

	# The source and widened captures intentionally share the exact opponent budget.
	# Refuse to splice the played candidate if that response set ever drifts.
	if JSON.stringify(source_row.get("opponent_responses", [])) != JSON.stringify(wide_row.get("opponent_responses", [])):
		return wide_row

	var played_variant: Variant = source_candidates[source_selected_index]
	if not (played_variant is Dictionary):
		return wide_row
	var played_candidate: Dictionary = (played_variant as Dictionary).duplicate(true)
	played_candidate["candidate_index"] = 0
	played_candidate["selected"] = true
	played_candidate["preserved_from_source_search"] = true

	var merged: Array = [played_candidate]
	for candidate_variant: Variant in wide_candidates:
		if merged.size() >= capture_own_max_plans:
			break
		if not (candidate_variant is Dictionary):
			continue
		var candidate: Dictionary = (candidate_variant as Dictionary).duplicate(true)
		candidate["candidate_index"] = merged.size()
		candidate["selected"] = false
		merged.append(candidate)

	var repaired: Dictionary = wide_row.duplicate(true)
	repaired["candidates"] = merged
	repaired["candidate_count"] = merged.size()
	repaired["selected_candidate_index"] = 0
	repaired["selected_candidate_preserved"] = true
	repaired["complete_requested_matrix"] = (
		merged.size() == capture_own_max_plans
		and int(repaired.get("opponent_response_count", 0)) == capture_opponent_max_plans
	)
	return repaired


func _read_jsonl(path: String) -> Variant:
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_error("Cannot open self-play traces: %s" % path)
		return null
	var rows: Array = []
	while not file.eof_reached():
		var line: String = file.get_line().strip_edges()
		if line.is_empty():
			continue
		var parsed: Variant = JSON.parse_string(line)
		if not (parsed is Dictionary):
			push_error("Invalid JSONL row in %s" % path)
			file.close()
			return null
		rows.append(parsed)
	file.close()
	return rows


func _to_jsonl(rows: Array) -> String:
	var lines: Array[String] = []
	for row_variant: Variant in rows:
		if row_variant is Dictionary:
			lines.append(JSON.stringify(row_variant))
	return "" if lines.is_empty() else "\n".join(lines) + "\n"


func _write_text(path: String, text: String) -> bool:
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
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
	var i: int = 0
	while i < raw.size():
		var arg: String = str(raw[i]).strip_edges()
		if arg.is_empty():
			i += 1
			continue
		if arg.begins_with("--"):
			arg = arg.substr(2)
		if arg.contains("="):
			var parts: PackedStringArray = arg.split("=", true, 1)
			result[parts[0]] = parts[1]
		else:
			var next_value: String = ""
			if i + 1 < raw.size() and not str(raw[i + 1]).begins_with("-"):
				next_value = str(raw[i + 1]).strip_edges()
				i += 1
			result[arg] = next_value if not next_value.is_empty() else "true"
		i += 1
	return result
