extends Node
## Build pairwise value-model supervision from PR #56/#57 search-decision data.
##
## Each rejected continuation already has a real terminal continuation. For a clean
## sibling comparison, this tool continues the actually played candidate under the
## exact same modeled opponent response. Pair labels therefore compare two real
## simulator continuations that share the same decision and opponent response.
##
## Ordering policy:
##   win > draw > loss          (weight 1.0)
##   faster win > slower win    (weight 0.25)
##   loss-vs-loss is unlabeled so training never rewards merely delaying defeat.

const PureStateGameRollout = preload("res://src/simulation/pure_state_game_rollout.gd")
const PureStateCommandHexRules = preload("res://src/simulation/pure_state_command_hex_rules.gd")

const PAIR_SCHEMA_VERSION := 1
const MANIFEST_SCHEMA_VERSION := 1
const OUTCOME_PAIR_WEIGHT := 1.0
const FASTER_WIN_PAIR_WEIGHT := 0.25


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	var args: Dictionary = _parse_cmdline_kv()
	var out_dir: String = str(args.get("out", "user://self_play_dataset"))
	var abs_out: String = ProjectSettings.globalize_path(out_dir)
	var decisions_path: String = abs_out.path_join("search_decisions.jsonl")
	var rejected_path: String = abs_out.path_join("rejected_continuations.jsonl")
	var pairs_path: String = abs_out.path_join("ranking_pairs.jsonl")
	var manifest_path: String = abs_out.path_join("ranking_pairs_manifest.json")
	var continuation_turn_cap: int = maxi(0, int(args.get("continuation-turn-cap", 0)))

	var decisions_variant: Variant = _read_jsonl(decisions_path)
	var rejected_variant: Variant = _read_jsonl(rejected_path)
	if decisions_variant == null or rejected_variant == null:
		get_tree().quit(1)
		return
	var decisions: Array = decisions_variant as Array
	var rejected_rows: Array = rejected_variant as Array
	var decision_by_key: Dictionary = {}
	for decision_variant: Variant in decisions:
		if decision_variant is Dictionary:
			var decision: Dictionary = decision_variant as Dictionary
			decision_by_key[_decision_key(decision)] = decision

	var pairs: Array = []
	var considered: int = 0
	var selected_unlabeled: int = 0
	var rejected_unlabeled: int = 0
	var no_preference: int = 0
	var invalid: int = 0
	var outcome_pairs: int = 0
	var faster_win_pairs: int = 0

	for rejected_variant_row: Variant in rejected_rows:
		if not (rejected_variant_row is Dictionary):
			continue
		var rejected: Dictionary = rejected_variant_row as Dictionary
		considered += 1
		if not bool(rejected.get("valid", false)) or not bool(rejected.get("labeled", false)):
			rejected_unlabeled += 1
			continue

		var key: String = _continuation_decision_key(rejected)
		if not decision_by_key.has(key):
			push_error("Missing search decision for rejected continuation %s" % key)
			invalid += 1
			continue
		var decision: Dictionary = decision_by_key[key] as Dictionary
		var played_index: int = int(rejected.get("played_candidate_index", -1))
		var rejected_index: int = int(rejected.get("rejected_candidate_index", -1))
		var response_index: int = int(rejected.get("response_index", -1))
		if played_index < 0 or rejected_index < 0 or played_index == rejected_index:
			invalid += 1
			continue

		var selected_result: Dictionary = _continue_candidate(
			decision,
			played_index,
			response_index,
			continuation_turn_cap
		)
		if not bool(selected_result.get("valid", false)):
			invalid += 1
			continue
		if not bool(selected_result.get("labeled", false)):
			selected_unlabeled += 1
			continue

		var comparison: Dictionary = _compare_terminal_results(selected_result, rejected)
		if not bool(comparison.get("preferred", false)):
			no_preference += 1
			continue

		var selected_better: bool = bool(comparison.get("selected_better", false))
		var pair_kind: String = str(comparison.get("pair_kind", ""))
		var pair_weight: float = float(comparison.get("weight", 1.0))
		if pair_kind == "outcome":
			outcome_pairs += 1
		elif pair_kind == "faster_win":
			faster_win_pairs += 1

		var selected_state_variant: Variant = selected_result.get("state_after_first_turn", {})
		var rejected_state_variant: Variant = rejected.get("state_after_first_turn", {})
		if not (selected_state_variant is Dictionary) or not (rejected_state_variant is Dictionary):
			invalid += 1
			continue
		var selected_state: Dictionary = selected_state_variant as Dictionary
		var rejected_state: Dictionary = rejected_state_variant as Dictionary
		var selected_outcome: float = float(selected_result.get("perspective_outcome", 0.0))
		var rejected_outcome: float = float(rejected.get("perspective_outcome", 0.0))
		var selected_turns: int = int(selected_result.get("turns_played_after_branch", 0))
		var rejected_turns: int = int(rejected.get("turns_played_after_branch", 0))
		var source: Dictionary = {}
		var source_variant: Variant = decision.get("source", {})
		if source_variant is Dictionary:
			source = (source_variant as Dictionary).duplicate(true)

		pairs.append({
			"schema_version": PAIR_SCHEMA_VERSION,
			"game_id": str(decision.get("game_id", "")),
			"turn_index": int(decision.get("turn_index", 0)),
			"perspective_group": str(decision.get("perspective_group", "")),
			"opponent_group": str(decision.get("opponent_group", "")),
			"response_index": response_index,
			"pair_kind": pair_kind,
			"weight": pair_weight,
			"better_candidate_index": played_index if selected_better else rejected_index,
			"worse_candidate_index": rejected_index if selected_better else played_index,
			"better_state": selected_state.duplicate(true) if selected_better else rejected_state.duplicate(true),
			"worse_state": rejected_state.duplicate(true) if selected_better else selected_state.duplicate(true),
			"better_outcome": selected_outcome if selected_better else rejected_outcome,
			"worse_outcome": rejected_outcome if selected_better else selected_outcome,
			"better_turns_after_branch": selected_turns if selected_better else rejected_turns,
			"worse_turns_after_branch": rejected_turns if selected_better else selected_turns,
			"better_leaf_terminal": bool(selected_result.get("leaf_terminal", false)) if selected_better else _rejected_leaf_terminal(rejected),
			"worse_leaf_terminal": _rejected_leaf_terminal(rejected) if selected_better else bool(selected_result.get("leaf_terminal", false)),
			"priority_reasons": (rejected.get("priority_reasons", []) as Array).duplicate(true),
			"source": source,
		})

	var manifest: Dictionary = {
		"manifest_schema_version": MANIFEST_SCHEMA_VERSION,
		"pair_schema_version": PAIR_SCHEMA_VERSION,
		"source_decisions": "search_decisions.jsonl",
		"source_rejected_continuations": "rejected_continuations.jsonl",
		"pair_file": "ranking_pairs.jsonl",
		"rejected_rows_considered": considered,
		"pairs_written": pairs.size(),
		"outcome_pairs": outcome_pairs,
		"faster_win_pairs": faster_win_pairs,
		"rejected_unlabeled": rejected_unlabeled,
		"selected_sibling_unlabeled": selected_unlabeled,
		"no_preference": no_preference,
		"invalid": invalid,
		"outcome_pair_weight": OUTCOME_PAIR_WEIGHT,
		"faster_win_pair_weight": FASTER_WIN_PAIR_WEIGHT,
		"continuation_policy": "handwritten_greedy",
		"same_opponent_response": true,
		"loss_vs_loss_pairs": false,
	}
	var ok: bool = _write_text(pairs_path, _to_jsonl(pairs))
	ok = _write_text(manifest_path, JSON.stringify(manifest, "  ") + "\n") and ok
	print("[ranking-pairs] wrote %s" % pairs_path)
	print("[ranking-pairs] wrote %s" % manifest_path)
	print("[ranking-pairs] considered=%d pairs=%d outcome=%d faster_win=%d rejected_unlabeled=%d selected_unlabeled=%d no_preference=%d invalid=%d" % [
		considered,
		pairs.size(),
		outcome_pairs,
		faster_win_pairs,
		rejected_unlabeled,
		selected_unlabeled,
		no_preference,
		invalid,
	])
	get_tree().quit(0 if ok and invalid == 0 else 1)


func _continue_candidate(
	decision: Dictionary,
	candidate_index: int,
	response_index: int,
	continuation_turn_cap: int
) -> Dictionary:
	var candidates_variant: Variant = decision.get("candidates", [])
	if not (candidates_variant is Array):
		return {"valid": false, "error": "invalid_candidates"}
	var candidates: Array = candidates_variant as Array
	if candidate_index < 0 or candidate_index >= candidates.size():
		return {"valid": false, "error": "invalid_candidate_index"}
	var candidate_variant: Variant = candidates[candidate_index]
	if not (candidate_variant is Dictionary):
		return {"valid": false, "error": "invalid_candidate"}
	var candidate: Dictionary = candidate_variant as Dictionary
	var response: Dictionary = _response_by_index(candidate, response_index)
	if response.is_empty():
		return {"valid": false, "error": "missing_response"}

	var perspective_group: String = str(decision.get("perspective_group", ""))
	var opponent_group: String = str(decision.get("opponent_group", ""))
	var starting_variant: Variant = decision.get("starting_state", {})
	var leaf_variant: Variant = response.get("state_after_first_turn", {})
	if not (starting_variant is Dictionary) or not (leaf_variant is Dictionary):
		return {"valid": false, "error": "missing_branch_state"}
	var starting_state: Dictionary = (starting_variant as Dictionary).duplicate(true)
	var leaf_state: Dictionary = (leaf_variant as Dictionary).duplicate(true)

	var command_hexes: Dictionary = PureStateCommandHexRules.ensure_command_hexes(
		starting_state,
		perspective_group,
		opponent_group
	)
	leaf_state["command_hexes"] = command_hexes.duplicate(true)
	var previous_occupants: Dictionary = PureStateCommandHexRules.initial_occupants(
		starting_state,
		perspective_group,
		opponent_group,
		command_hexes
	)
	var capture: Dictionary = PureStateCommandHexRules.capture_after_complete_turn(
		leaf_state,
		perspective_group,
		opponent_group,
		command_hexes,
		previous_occupants
	)
	var completed: Dictionary = {}
	var completed_variant: Variant = capture.get("completed", {})
	if completed_variant is Dictionary:
		completed = completed_variant as Dictionary
	var immediate: Dictionary = _immediate_branch_outcome(
		leaf_state,
		perspective_group,
		opponent_group,
		bool(completed.get(perspective_group, false)),
		bool(completed.get(opponent_group, false))
	)
	if bool(immediate.get("terminal", false)):
		return _continuation_result(
			true,
			true,
			true,
			str(immediate.get("winner", "")),
			str(immediate.get("termination_reason", "")),
			0,
			leaf_state,
			leaf_state,
			perspective_group
		)

	var source: Dictionary = {}
	var source_variant: Variant = decision.get("source", {})
	if source_variant is Dictionary:
		source = source_variant as Dictionary
	var source_max_turns: int = int(source.get("max_turns", PureStateGameRollout.DEFAULT_MAX_TURNS))
	var decision_turn_index: int = int(decision.get("turn_index", 0))
	var full_remaining_turns: int = maxi(0, source_max_turns - decision_turn_index)
	var remaining_turns: int = full_remaining_turns
	if continuation_turn_cap > 0:
		remaining_turns = mini(remaining_turns, continuation_turn_cap)
	var truncated: bool = remaining_turns < full_remaining_turns
	var turn_limit_winner: String = str(source.get("turn_limit_winner", ""))
	if remaining_turns <= 0:
		var adjudicated: bool = not turn_limit_winner.is_empty() and not truncated
		return _continuation_result(
			true,
			adjudicated,
			false,
			turn_limit_winner if adjudicated else "",
			"turn_limit_adjudication" if adjudicated else "turn_limit",
			0,
			leaf_state,
			leaf_state,
			perspective_group
		)

	var budget: Dictionary = {}
	var budget_variant: Variant = decision.get("budget", {})
	if budget_variant is Dictionary:
		budget = budget_variant as Dictionary
	var rollout_turn_limit_winner: String = "" if truncated else turn_limit_winner
	var rollout: Dictionary = PureStateGameRollout.play_game(
		leaf_state,
		perspective_group,
		opponent_group,
		remaining_turns,
		int(budget.get("max_actions_per_unit", PureStateGameRollout.DEFAULT_MAX_ACTIONS_PER_UNIT)),
		int(budget.get("own_max_plans", PureStateGameRollout.DEFAULT_OWN_MAX_PLANS)),
		int(budget.get("opponent_max_plans", PureStateGameRollout.DEFAULT_OPPONENT_MAX_PLANS)),
		false,
		rollout_turn_limit_winner
	)
	if not bool(rollout.get("valid", false)):
		return {"valid": false, "error": str(rollout.get("status", "continuation_failed"))}
	var status: String = str(rollout.get("status", ""))
	var winner: String = str(rollout.get("winner", ""))
	var final_state: Dictionary = leaf_state
	var final_state_variant: Variant = rollout.get("final_state", leaf_state)
	if final_state_variant is Dictionary:
		final_state = (final_state_variant as Dictionary).duplicate(true)
	return _continuation_result(
		true,
		status == "terminal",
		false,
		winner,
		str(rollout.get("termination_reason", "")),
		int(rollout.get("turns_played", 0)),
		leaf_state,
		final_state,
		perspective_group
	)


func _continuation_result(
	valid: bool,
	labeled: bool,
	leaf_terminal: bool,
	winner: String,
	termination_reason: String,
	turns_played_after_branch: int,
	leaf_state: Dictionary,
	final_state: Dictionary,
	perspective_group: String
) -> Dictionary:
	var outcome: float = 0.0
	if labeled and not winner.is_empty():
		outcome = 1.0 if winner == perspective_group else -1.0
	return {
		"valid": valid,
		"labeled": labeled,
		"leaf_terminal": leaf_terminal,
		"winner": winner,
		"perspective_outcome": outcome,
		"termination_reason": termination_reason,
		"turns_played_after_branch": turns_played_after_branch,
		"state_after_first_turn": leaf_state.duplicate(true),
		"final_state": final_state.duplicate(true),
	}


func _compare_terminal_results(selected: Dictionary, rejected: Dictionary) -> Dictionary:
	var selected_outcome: float = float(selected.get("perspective_outcome", 0.0))
	var rejected_outcome: float = float(rejected.get("perspective_outcome", 0.0))
	if not is_equal_approx(selected_outcome, rejected_outcome):
		return {
			"preferred": true,
			"selected_better": selected_outcome > rejected_outcome,
			"pair_kind": "outcome",
			"weight": OUTCOME_PAIR_WEIGHT,
		}
	# Only break ties between wins. Delaying a loss is intentionally not rewarded.
	if is_equal_approx(selected_outcome, 1.0):
		var selected_turns: int = int(selected.get("turns_played_after_branch", 0))
		var rejected_turns: int = int(rejected.get("turns_played_after_branch", 0))
		if selected_turns != rejected_turns:
			return {
				"preferred": true,
				"selected_better": selected_turns < rejected_turns,
				"pair_kind": "faster_win",
				"weight": FASTER_WIN_PAIR_WEIGHT,
			}
	return {"preferred": false}


func _rejected_leaf_terminal(rejected: Dictionary) -> bool:
	if not bool(rejected.get("labeled", false)):
		return false
	if int(rejected.get("turns_played_after_branch", 0)) != 0:
		return false
	return str(rejected.get("termination_reason", "")) in [
		"elimination",
		"command_hex_capture",
		"simultaneous_command_hex_capture",
	]


func _immediate_branch_outcome(
	state: Dictionary,
	perspective_group: String,
	opponent_group: String,
	captured_by_perspective: bool,
	captured_by_opponent: bool
) -> Dictionary:
	if captured_by_perspective and captured_by_opponent:
		return {"terminal": true, "winner": "", "termination_reason": "simultaneous_command_hex_capture"}
	var own_alive: int = _living_units(state, perspective_group)
	var opponent_alive: int = _living_units(state, opponent_group)
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


func _living_units(state: Dictionary, group_name: String) -> int:
	for group_variant: Variant in state.get("groups", []):
		if not (group_variant is Dictionary):
			continue
		var group: Dictionary = group_variant as Dictionary
		if str(group.get("name", "")) != group_name:
			continue
		var count: int = 0
		for unit_variant: Variant in group.get("units", []):
			if unit_variant is Dictionary and int((unit_variant as Dictionary).get("health", 0)) > 0:
				count += 1
		return count
	return 0


func _response_by_index(candidate: Dictionary, response_index: int) -> Dictionary:
	for response_variant: Variant in candidate.get("responses", []):
		if response_variant is Dictionary and int((response_variant as Dictionary).get("response_index", -1)) == response_index:
			return response_variant as Dictionary
	return {}


func _decision_key(decision: Dictionary) -> String:
	return "%s|%d|%s" % [
		str(decision.get("game_id", "")),
		int(decision.get("turn_index", 0)),
		str(decision.get("perspective_group", "")),
	]


func _continuation_decision_key(row: Dictionary) -> String:
	return "%s|%d|%s" % [
		str(row.get("game_id", "")),
		int(row.get("turn_index", 0)),
		str(row.get("perspective_group", "")),
	]


func _read_jsonl(path: String) -> Variant:
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_error("Cannot open JSONL: %s" % path)
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
