extends Node
## Selectively label rejected search alternatives with real simulator continuations.
##
## This is intentionally a post-process over search_decisions.jsonl. It does not
## change gameplay search or roll out every leaf. Rejected alternatives are ranked
## by: neural-vs-handwritten disagreement, close neural scores, then tactical swing.
## The chosen branch is continued with the canonical handwritten GameplayAI policy.

const PureStateEvaluator = preload("res://src/simulation/pure_state_evaluator.gd")
const PureStateNeuralEvaluator = preload("res://src/simulation/pure_state_neural_evaluator.gd")
const PureStateGameRollout = preload("res://src/simulation/pure_state_game_rollout.gd")
const PureStateCommandHexRules = preload("res://src/simulation/pure_state_command_hex_rules.gd")

const LABEL_SCHEMA_VERSION := 1
const MANIFEST_SCHEMA_VERSION := 1
const DEFAULT_MAX_CONTINUATIONS := 64
const DEFAULT_NEURAL_CLOSE_THRESHOLD := 100.0
const TACTICAL_REASON_THRESHOLD := 0.75


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	var args := _parse_cmdline_kv()
	var out_dir := str(args.get("out", "user://self_play_dataset"))
	var abs_out := ProjectSettings.globalize_path(out_dir)
	var decisions_path := abs_out.path_join("search_decisions.jsonl")
	var labels_path := abs_out.path_join("rejected_continuations.jsonl")
	var manifest_path := abs_out.path_join("rejected_continuations_manifest.json")
	var max_continuations := maxi(0, int(args.get("max-continuations", DEFAULT_MAX_CONTINUATIONS)))
	var continuation_turn_cap := maxi(0, int(args.get("continuation-turn-cap", 0)))
	var neural_close_threshold := maxf(0.0, float(args.get("neural-close-threshold", DEFAULT_NEURAL_CLOSE_THRESHOLD)))
	var neural_checkpoint := str(args.get("neural-checkpoint", "")).strip_edges()
	var neural_enabled := not neural_checkpoint.is_empty()
	var neural_settings := {"checkpoint_path": neural_checkpoint} if neural_enabled else {}

	var decisions_variant: Variant = _read_jsonl(decisions_path)
	if decisions_variant == null:
		get_tree().quit(1)
		return
	var decisions: Array = decisions_variant

	var selections: Array = []
	var rejected_considered := 0
	var neural_scored_decisions := 0
	for decision_variant in decisions:
		if not (decision_variant is Dictionary):
			continue
		var decision: Dictionary = decision_variant
		var built := _build_rejected_selections(
			decision,
			neural_enabled,
			neural_settings,
			neural_close_threshold
		)
		if not bool(built.get("valid", false)):
			push_error("Rejected-continuation prioritization failed game=%s turn=%d side=%s error=%s" % [
				str(decision.get("game_id", "")),
				int(decision.get("turn_index", 0)),
				str(decision.get("perspective_group", "")),
				str(built.get("error", "unknown")),
			])
			PureStateNeuralEvaluator.shutdown()
			get_tree().quit(1)
			return
		rejected_considered += int(built.get("rejected_count", 0))
		if bool(built.get("neural_scored", false)):
			neural_scored_decisions += 1
		selections.append_array((built.get("selections", []) as Array).duplicate(true))

	selections.sort_custom(func(a, b):
		var a_score := float((a as Dictionary).get("priority_score", 0.0))
		var b_score := float((b as Dictionary).get("priority_score", 0.0))
		if not is_equal_approx(a_score, b_score):
			return a_score > b_score
		var a_key := _selection_key(a as Dictionary)
		var b_key := _selection_key(b as Dictionary)
		return a_key < b_key
	)
	if max_continuations > 0 and selections.size() > max_continuations:
		selections = selections.slice(0, max_continuations)
	elif max_continuations == 0:
		selections = []

	var labels: Array = []
	var labeled_count := 0
	var unlabeled_count := 0
	var invalid_count := 0
	var reason_counts: Dictionary = {}
	for selection_variant in selections:
		if not (selection_variant is Dictionary):
			continue
		var selection: Dictionary = selection_variant
		var label := _label_selection(selection, continuation_turn_cap)
		if not bool(label.get("valid", false)):
			invalid_count += 1
		else:
			if bool(label.get("labeled", false)):
				labeled_count += 1
			else:
				unlabeled_count += 1
		labels.append(label)
		for reason_variant in selection.get("priority_reasons", []):
			var reason := str(reason_variant)
			reason_counts[reason] = int(reason_counts.get(reason, 0)) + 1

	var manifest := {
		"manifest_schema_version": MANIFEST_SCHEMA_VERSION,
		"label_schema_version": LABEL_SCHEMA_VERSION,
		"source_file": "search_decisions.jsonl",
		"label_file": "rejected_continuations.jsonl",
		"decisions_considered": decisions.size(),
		"rejected_candidates_considered": rejected_considered,
		"continuations_selected": selections.size(),
		"continuations_labeled": labeled_count,
		"continuations_unlabeled": unlabeled_count,
		"continuations_invalid": invalid_count,
		"max_continuations": max_continuations,
		"continuation_turn_cap": continuation_turn_cap,
		"neural_prioritization_enabled": neural_enabled,
		"neural_scored_decisions": neural_scored_decisions,
		"neural_close_threshold": neural_close_threshold,
		"priority_reason_counts": reason_counts,
		"continuation_policy": "handwritten_greedy",
	}
	if neural_enabled:
		manifest["neural_checkpoint"] = neural_checkpoint

	var write_ok := _write_text(labels_path, _to_jsonl(labels))
	write_ok = _write_text(manifest_path, JSON.stringify(manifest, "  ") + "\n") and write_ok
	PureStateNeuralEvaluator.shutdown()
	print("[rejected-continuations] wrote %s" % labels_path)
	print("[rejected-continuations] wrote %s" % manifest_path)
	print("[rejected-continuations] decisions=%d rejected=%d selected=%d labeled=%d unlabeled=%d invalid=%d neural=%s reasons=%s" % [
		decisions.size(),
		rejected_considered,
		selections.size(),
		labeled_count,
		unlabeled_count,
		invalid_count,
		str(neural_enabled),
		str(reason_counts),
	])
	get_tree().quit(0 if write_ok and invalid_count == 0 else 1)


func _build_rejected_selections(
	decision: Dictionary,
	neural_enabled: bool,
	neural_settings: Dictionary,
	neural_close_threshold: float
) -> Dictionary:
	var candidates_variant = decision.get("candidates", [])
	if not (candidates_variant is Array):
		return {"valid": false, "error": "invalid_candidates"}
	var candidates: Array = candidates_variant
	if candidates.size() < 2:
		return {"valid": true, "selections": [], "rejected_count": 0, "neural_scored": false}
	var selected_index := int(decision.get("selected_candidate_index", -1))
	if selected_index < 0 or selected_index >= candidates.size():
		return {"valid": false, "error": "missing_selected_candidate"}

	var perspective_group := str(decision.get("perspective_group", ""))
	var opponent_group := str(decision.get("opponent_group", ""))
	var start_state_variant = decision.get("starting_state", {})
	if not (start_state_variant is Dictionary):
		return {"valid": false, "error": "invalid_starting_state"}
	var start_eval := PureStateEvaluator.evaluate_breakdown(start_state_variant as Dictionary, perspective_group)
	if not bool(start_eval.get("valid", false)):
		return {"valid": false, "error": "starting_evaluation_failed"}

	var neural_summaries: Array = []
	var neural_best_index := -1
	if neural_enabled:
		for candidate_variant in candidates:
			if not (candidate_variant is Dictionary):
				return {"valid": false, "error": "invalid_candidate"}
			var summary := _neural_candidate_summary(
				candidate_variant as Dictionary,
				perspective_group,
				opponent_group,
				neural_settings
			)
			if not bool(summary.get("valid", false)):
				return {"valid": false, "error": str(summary.get("error", "neural_evaluation_failed"))}
			neural_summaries.append(summary)
		for index in range(neural_summaries.size()):
			if neural_best_index < 0 or _neural_summary_before(
				neural_summaries[index] as Dictionary,
				neural_summaries[neural_best_index] as Dictionary
			):
				neural_best_index = index

	var selected_neural: Dictionary = {}
	if neural_enabled:
		selected_neural = neural_summaries[selected_index] as Dictionary

	var selections: Array = []
	var rejected_count := 0
	for candidate_index in range(candidates.size()):
		if candidate_index == selected_index:
			continue
		rejected_count += 1
		var candidate_variant = candidates[candidate_index]
		if not (candidate_variant is Dictionary):
			continue
		var candidate: Dictionary = candidate_variant
		var tactical_score := _tactical_swing_score(candidate, start_eval)
		var reasons: Array[String] = []
		var priority_score := tactical_score * 1000.0
		var response_index := _handwritten_worst_response_index(candidate)
		var neural_gap := -1.0
		var candidate_neural: Dictionary = {}

		if neural_enabled:
			candidate_neural = neural_summaries[candidate_index] as Dictionary
			var selected_worst := float(selected_neural.get("worst_case_score", 0.0))
			var candidate_worst := float(candidate_neural.get("worst_case_score", 0.0))
			neural_gap = absf(selected_worst - candidate_worst)
			var neural_disagreement := neural_best_index == candidate_index and neural_best_index != selected_index
			if neural_disagreement:
				reasons.append("neural_handwritten_disagreement")
				priority_score += 100000.0
			if neural_gap <= neural_close_threshold:
				reasons.append("neural_scores_close")
				priority_score += 50000.0 + maxf(0.0, neural_close_threshold - neural_gap)
			if neural_disagreement or neural_gap <= neural_close_threshold:
				response_index = int(candidate_neural.get("worst_response_index", response_index))

		if tactical_score >= TACTICAL_REASON_THRESHOLD:
			reasons.append("tactically_important")
			priority_score += 10000.0
		if reasons.is_empty():
			reasons.append("priority_fallback")

		selections.append({
			"decision": decision.duplicate(true),
			"candidate_index": candidate_index,
			"response_index": response_index,
			"priority_score": priority_score,
			"priority_reasons": reasons,
			"tactical_swing_score": tactical_score,
			"neural_gap": neural_gap,
			"neural_candidate_summary": candidate_neural.duplicate(true),
			"neural_selected_summary": selected_neural.duplicate(true),
		})

	return {
		"valid": true,
		"selections": selections,
		"rejected_count": rejected_count,
		"neural_scored": neural_enabled,
	}


func _neural_candidate_summary(
	candidate: Dictionary,
	perspective_group: String,
	opponent_group: String,
	neural_settings: Dictionary
) -> Dictionary:
	var responses_variant = candidate.get("responses", [])
	if not (responses_variant is Array) or (responses_variant as Array).is_empty():
		return {"valid": false, "error": "candidate_missing_responses"}
	var responses: Array = responses_variant
	var worst_score := 0.0
	var total := 0.0
	var worst_response_index := -1
	var initialized := false
	for response_variant in responses:
		if not (response_variant is Dictionary):
			return {"valid": false, "error": "invalid_response"}
		var response: Dictionary = response_variant
		var state_variant = response.get("state_after_first_turn", {})
		if not (state_variant is Dictionary):
			return {"valid": false, "error": "missing_response_state"}
		var evaluation := PureStateNeuralEvaluator.evaluate_breakdown(
			state_variant as Dictionary,
			perspective_group,
			opponent_group,
			neural_settings
		)
		if not bool(evaluation.get("valid", false)):
			return {"valid": false, "error": str(evaluation.get("error", "neural_evaluation_failed"))}
		var score := float(evaluation.get("total", 0.0))
		total += score
		if not initialized or score < worst_score:
			initialized = true
			worst_score = score
			worst_response_index = int(response.get("response_index", 0))
	return {
		"valid": true,
		"worst_case_score": worst_score,
		"average_score": total / float(responses.size()),
		"worst_response_index": worst_response_index,
	}


func _neural_summary_before(a: Dictionary, b: Dictionary) -> bool:
	var a_worst := float(a.get("worst_case_score", 0.0))
	var b_worst := float(b.get("worst_case_score", 0.0))
	if not is_equal_approx(a_worst, b_worst):
		return a_worst > b_worst
	return float(a.get("average_score", 0.0)) > float(b.get("average_score", 0.0))


func _tactical_swing_score(candidate: Dictionary, start_eval: Dictionary) -> float:
	var best := 0.0
	for response_variant in candidate.get("responses", []):
		if not (response_variant is Dictionary):
			continue
		var evaluation_variant = (response_variant as Dictionary).get("handwritten_evaluation", {})
		if not (evaluation_variant is Dictionary):
			continue
		var evaluation: Dictionary = evaluation_variant
		best = maxf(best, absf(float(evaluation.get("terminal", 0.0)) - float(start_eval.get("terminal", 0.0))) / 100000.0)
		best = maxf(best, absf(float(evaluation.get("unit_count", 0.0)) - float(start_eval.get("unit_count", 0.0))) / 400.0)
		best = maxf(best, absf(float(evaluation.get("health", 0.0)) - float(start_eval.get("health", 0.0))) / 250.0)
		best = maxf(best, absf(float(evaluation.get("objective", 0.0)) - float(start_eval.get("objective", 0.0))) / 500.0)
	return best


func _handwritten_worst_response_index(candidate: Dictionary) -> int:
	var worst_index := 0
	var worst_score := 0.0
	var initialized := false
	for response_variant in candidate.get("responses", []):
		if not (response_variant is Dictionary):
			continue
		var response: Dictionary = response_variant
		var evaluation_variant = response.get("handwritten_evaluation", {})
		if not (evaluation_variant is Dictionary):
			continue
		var score := float((evaluation_variant as Dictionary).get("total", 0.0))
		if not initialized or score < worst_score:
			initialized = true
			worst_score = score
			worst_index = int(response.get("response_index", 0))
	return worst_index


func _label_selection(selection: Dictionary, continuation_turn_cap: int) -> Dictionary:
	var decision_variant = selection.get("decision", {})
	if not (decision_variant is Dictionary):
		return {"valid": false, "error": "missing_decision"}
	var decision: Dictionary = decision_variant
	var candidates_variant = decision.get("candidates", [])
	if not (candidates_variant is Array):
		return {"valid": false, "error": "invalid_candidates"}
	var candidates: Array = candidates_variant
	var candidate_index := int(selection.get("candidate_index", -1))
	if candidate_index < 0 or candidate_index >= candidates.size():
		return {"valid": false, "error": "invalid_candidate_index"}
	var candidate_variant = candidates[candidate_index]
	if not (candidate_variant is Dictionary):
		return {"valid": false, "error": "invalid_candidate"}
	var candidate: Dictionary = candidate_variant
	var response_index := int(selection.get("response_index", -1))
	var response := _response_by_index(candidate, response_index)
	if response.is_empty():
		return {"valid": false, "error": "missing_response"}

	var perspective_group := str(decision.get("perspective_group", ""))
	var opponent_group := str(decision.get("opponent_group", ""))
	var starting_variant = decision.get("starting_state", {})
	var leaf_variant = response.get("state_after_first_turn", {})
	if not (starting_variant is Dictionary) or not (leaf_variant is Dictionary):
		return {"valid": false, "error": "missing_branch_state"}
	var starting_state: Dictionary = (starting_variant as Dictionary).duplicate(true)
	var leaf_state: Dictionary = (leaf_variant as Dictionary).duplicate(true)
	var command_hexes := PureStateCommandHexRules.ensure_command_hexes(starting_state, perspective_group, opponent_group)
	leaf_state["command_hexes"] = command_hexes.duplicate(true)
	var previous_occupants := PureStateCommandHexRules.initial_occupants(
		starting_state,
		perspective_group,
		opponent_group,
		command_hexes
	)
	var capture := PureStateCommandHexRules.capture_after_complete_turn(
		leaf_state,
		perspective_group,
		opponent_group,
		command_hexes,
		previous_occupants
	)
	var completed_variant = capture.get("completed", {})
	var completed: Dictionary = completed_variant if completed_variant is Dictionary else {}
	var captured_by_perspective := bool(completed.get(perspective_group, false))
	var captured_by_opponent := bool(completed.get(opponent_group, false))

	var immediate := _immediate_branch_outcome(
		leaf_state,
		perspective_group,
		opponent_group,
		captured_by_perspective,
		captured_by_opponent
	)
	if bool(immediate.get("terminal", false)):
		return _build_label_record(
			selection,
			candidate,
			response,
			true,
			"terminal",
			str(immediate.get("winner", "")),
			str(immediate.get("termination_reason", "")),
			0,
			leaf_state,
			0
		)

	var source_variant = decision.get("source", {})
	var source: Dictionary = source_variant if source_variant is Dictionary else {}
	var source_max_turns := int(source.get("max_turns", PureStateGameRollout.DEFAULT_MAX_TURNS))
	var turn_index := int(decision.get("turn_index", 0))
	var remaining_turns := maxi(0, source_max_turns - turn_index)
	if continuation_turn_cap > 0:
		remaining_turns = mini(remaining_turns, continuation_turn_cap)
	var turn_limit_winner := str(source.get("turn_limit_winner", ""))
	if remaining_turns <= 0:
		var adjudicated := not turn_limit_winner.is_empty()
		return _build_label_record(
			selection,
			candidate,
			response,
			true,
			"terminal" if adjudicated else "turn_limit",
			turn_limit_winner if adjudicated else "",
			"turn_limit_adjudication" if adjudicated else "turn_limit",
			0,
			leaf_state,
			0
		)

	var budget_variant = decision.get("budget", {})
	var budget: Dictionary = budget_variant if budget_variant is Dictionary else {}
	var rollout := PureStateGameRollout.play_game(
		leaf_state,
		perspective_group,
		opponent_group,
		remaining_turns,
		int(budget.get("max_actions_per_unit", PureStateGameRollout.DEFAULT_MAX_ACTIONS_PER_UNIT)),
		int(budget.get("own_max_plans", PureStateGameRollout.DEFAULT_OWN_MAX_PLANS)),
		int(budget.get("opponent_max_plans", PureStateGameRollout.DEFAULT_OPPONENT_MAX_PLANS)),
		false,
		turn_limit_winner
	)
	if not bool(rollout.get("valid", false)):
		return {"valid": false, "error": str(rollout.get("status", "continuation_failed"))}
	var status := str(rollout.get("status", ""))
	return _build_label_record(
		selection,
		candidate,
		response,
		true,
		status,
		str(rollout.get("winner", "")),
		str(rollout.get("termination_reason", "")),
		int(rollout.get("turns_played", 0)),
		(rollout.get("final_state", leaf_state) as Dictionary).duplicate(true),
		remaining_turns
	)


func _immediate_branch_outcome(
	state: Dictionary,
	perspective_group: String,
	opponent_group: String,
	captured_by_perspective: bool,
	captured_by_opponent: bool
) -> Dictionary:
	if captured_by_perspective and captured_by_opponent:
		return {"terminal": true, "winner": "", "termination_reason": "simultaneous_command_hex_capture"}
	var own_alive := _living_units(state, perspective_group)
	var opponent_alive := _living_units(state, opponent_group)
	if own_alive <= 0 and opponent_alive <= 0:
		return {"terminal": true, "winner": "", "termination_reason": "elimination"}
	if own_alive <= 0:
		return {"terminal": true, "winner": opponent_group, "termination_reason": "elimination"}
	if opponent_alive <= 0:
		return {"terminal": true, "winner": perspective_group, "termination_reason": "elimination"}
	if captured_by_perspective:
		return {"terminal": true, "winner": perspective_group, "termination_reason": "command_hex_capture"}
	if captured_by_opponent:
		return {"terminal": true, "winner": opponent_group, "termination_reason": "command_hex_capture"}
	return {"terminal": false, "winner": "", "termination_reason": ""}


func _build_label_record(
	selection: Dictionary,
	candidate: Dictionary,
	response: Dictionary,
	valid: bool,
	status: String,
	winner: String,
	termination_reason: String,
	turns_played_after_branch: int,
	final_state: Dictionary,
	continuation_turn_budget: int
) -> Dictionary:
	var decision: Dictionary = selection.get("decision", {})
	var perspective_group := str(decision.get("perspective_group", ""))
	var labeled := valid and status == "terminal"
	var perspective_outcome := 0.0
	if labeled and not winner.is_empty():
		perspective_outcome = 1.0 if winner == perspective_group else -1.0
	return {
		"schema_version": LABEL_SCHEMA_VERSION,
		"valid": valid,
		"labeled": labeled,
		"game_id": str(decision.get("game_id", "")),
		"turn_index": int(decision.get("turn_index", 0)),
		"perspective_group": perspective_group,
		"opponent_group": str(decision.get("opponent_group", "")),
		"selected_candidate_index": int(decision.get("selected_candidate_index", -1)),
		"rejected_candidate_index": int(selection.get("candidate_index", -1)),
		"response_index": int(selection.get("response_index", -1)),
		"rejected_actions": (candidate.get("actions", []) as Array).duplicate(true),
		"opponent_actions": (response.get("opponent_actions", []) as Array).duplicate(true),
		"priority_score": float(selection.get("priority_score", 0.0)),
		"priority_reasons": (selection.get("priority_reasons", []) as Array).duplicate(true),
		"tactical_swing_score": float(selection.get("tactical_swing_score", 0.0)),
		"neural_gap": float(selection.get("neural_gap", -1.0)),
		"neural_selected_summary": (selection.get("neural_selected_summary", {}) as Dictionary).duplicate(true),
		"neural_rejected_summary": (selection.get("neural_candidate_summary", {}) as Dictionary).duplicate(true),
		"handwritten_rejected_worst_case_score": float(candidate.get("handwritten_worst_case_score", 0.0)),
		"state_after_first_turn": (response.get("state_after_first_turn", {}) as Dictionary).duplicate(true),
		"continuation_policy": "handwritten_greedy",
		"continuation_turn_budget": continuation_turn_budget,
		"turns_played_after_branch": turns_played_after_branch,
		"status": status,
		"winner": winner,
		"perspective_outcome": perspective_outcome,
		"termination_reason": termination_reason,
		"final_state": final_state.duplicate(true),
		"source": (decision.get("source", {}) as Dictionary).duplicate(true),
	}


func _response_by_index(candidate: Dictionary, response_index: int) -> Dictionary:
	for response_variant in candidate.get("responses", []):
		if response_variant is Dictionary and int((response_variant as Dictionary).get("response_index", -1)) == response_index:
			return response_variant as Dictionary
	return {}


func _living_units(state: Dictionary, group_name: String) -> int:
	for group_variant in state.get("groups", []):
		if not (group_variant is Dictionary):
			continue
		var group: Dictionary = group_variant
		if str(group.get("name", "")) != group_name:
			continue
		var count := 0
		for unit_variant in group.get("units", []):
			if unit_variant is Dictionary and int((unit_variant as Dictionary).get("health", 0)) > 0:
				count += 1
		return count
	return 0


func _selection_key(selection: Dictionary) -> String:
	var decision: Dictionary = selection.get("decision", {})
	return "%s|%08d|%s|%08d|%08d" % [
		str(decision.get("game_id", "")),
		int(decision.get("turn_index", 0)),
		str(decision.get("perspective_group", "")),
		int(selection.get("candidate_index", -1)),
		int(selection.get("response_index", -1)),
	]


func _read_jsonl(path: String) -> Variant:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_error("Cannot open search decisions: %s" % path)
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
