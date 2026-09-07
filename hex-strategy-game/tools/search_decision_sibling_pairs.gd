extends Node
## Build dense sibling-ranking supervision from stored search decisions.
##
## Rejected-continuation rows identify neural-interesting decisions. This tool then
## expands each selected decision to every stored candidate, forces the same modeled
## opponent response for all siblings, continues each branch once with the real
## simulator, and emits every useful pairwise preference.
##
## Selection is family-diverse so held-out value families are much more likely to
## contain ranking pairs. Normal gameplay search is untouched.

const RankingHelperScript = preload("res://tools/search_decision_ranking_pairs.gd")

const PAIR_SCHEMA_VERSION := 2
const MANIFEST_SCHEMA_VERSION := 2
const OUTCOME_PAIR_WEIGHT := 1.0
const FASTER_WIN_PAIR_WEIGHT := 0.25
const DEFAULT_MAX_DECISIONS := 24


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	var args: Dictionary = _parse_cmdline_kv()
	var out_dir: String = str(args.get("out", "user://self_play_dataset"))
	var abs_out: String = ProjectSettings.globalize_path(out_dir)
	var decisions_path: String = abs_out.path_join("search_decisions.jsonl")
	var rejected_path: String = abs_out.path_join("rejected_continuations.jsonl")
	var pairs_path: String = abs_out.path_join("ranking_pairs.jsonl")
	var branches_path: String = abs_out.path_join("sibling_branches.jsonl")
	var manifest_path: String = abs_out.path_join("ranking_pairs_manifest.json")
	var max_decisions: int = maxi(1, int(args.get("max-decisions", DEFAULT_MAX_DECISIONS)))
	var continuation_turn_cap: int = maxi(0, int(args.get("continuation-turn-cap", 0)))

	var decisions_variant: Variant = _read_jsonl(decisions_path)
	var rejected_variant: Variant = _read_jsonl(rejected_path)
	if decisions_variant == null or rejected_variant == null:
		get_tree().quit(1)
		return
	var decisions: Array = decisions_variant as Array
	var rejected_rows: Array = rejected_variant as Array

	var neural_priority_by_key: Dictionary = {}
	var reasons_by_key: Dictionary = {}
	for row_variant: Variant in rejected_rows:
		if not (row_variant is Dictionary):
			continue
		var row: Dictionary = row_variant as Dictionary
		var key: String = _continuation_decision_key(row)
		var score: float = float(row.get("priority_score", 0.0))
		neural_priority_by_key[key] = maxf(score, float(neural_priority_by_key.get(key, 0.0)))
		var reasons: Array = reasons_by_key.get(key, []) as Array
		for reason_variant: Variant in row.get("priority_reasons", []):
			var reason: String = str(reason_variant)
			if not reason in reasons:
				reasons.append(reason)
		reasons_by_key[key] = reasons

	var descriptors: Array = []
	var decision_by_key: Dictionary = {}
	for decision_variant: Variant in decisions:
		if not (decision_variant is Dictionary):
			continue
		var decision: Dictionary = decision_variant as Dictionary
		var candidates_variant: Variant = decision.get("candidates", [])
		if not (candidates_variant is Array) or (candidates_variant as Array).size() < 2:
			continue
		var key: String = _decision_key(decision)
		decision_by_key[key] = decision
		var source: Dictionary = {}
		var source_variant: Variant = decision.get("source", {})
		if source_variant is Dictionary:
			source = source_variant as Dictionary
		var family: String = str(source.get("base_scenario_id", decision.get("scenario_id", "unknown")))
		var neural_priority: float = float(neural_priority_by_key.get(key, 0.0))
		var fallback_priority: float = _decision_fallback_priority(decision)
		descriptors.append({
			"key": key,
			"family": family,
			"neural_priority": neural_priority,
			"fallback_priority": fallback_priority,
			"priority_score": neural_priority + fallback_priority,
			"neural_priority_hit": neural_priority_by_key.has(key),
		})

	var selected_descriptors: Array = _select_family_diverse(descriptors, max_decisions)
	var helper: Node = RankingHelperScript.new()
	var pairs: Array = []
	var branch_rows: Array = []
	var outcome_pairs: int = 0
	var faster_win_pairs: int = 0
	var no_preference: int = 0
	var branch_unlabeled: int = 0
	var invalid: int = 0
	var branch_continuations: int = 0
	var selected_by_family: Dictionary = {}
	var neural_priority_decisions: int = 0

	for descriptor_variant: Variant in selected_descriptors:
		var descriptor: Dictionary = descriptor_variant as Dictionary
		var key: String = str(descriptor.get("key", ""))
		if not decision_by_key.has(key):
			invalid += 1
			continue
		var decision: Dictionary = decision_by_key[key] as Dictionary
		var family: String = str(descriptor.get("family", "unknown"))
		selected_by_family[family] = int(selected_by_family.get(family, 0)) + 1
		if bool(descriptor.get("neural_priority_hit", false)):
			neural_priority_decisions += 1
		var shared_response_index: int = _shared_response_index(decision)
		if shared_response_index < 0:
			invalid += 1
			continue
		var candidates: Array = decision.get("candidates", []) as Array
		var branches: Array = []
		for candidate_index: int in range(candidates.size()):
			branch_continuations += 1
			var result: Dictionary = helper._continue_candidate(
				decision,
				candidate_index,
				shared_response_index,
				continuation_turn_cap
			)
			if not bool(result.get("valid", false)):
				invalid += 1
				continue
			var branch_record: Dictionary = {
				"game_id": str(decision.get("game_id", "")),
				"turn_index": int(decision.get("turn_index", 0)),
				"perspective_group": str(decision.get("perspective_group", "")),
				"opponent_group": str(decision.get("opponent_group", "")),
				"family": family,
				"candidate_index": candidate_index,
				"response_index": shared_response_index,
				"labeled": bool(result.get("labeled", false)),
				"leaf_terminal": bool(result.get("leaf_terminal", false)),
				"winner": str(result.get("winner", "")),
				"perspective_outcome": float(result.get("perspective_outcome", 0.0)),
				"turns_played_after_branch": int(result.get("turns_played_after_branch", 0)),
				"termination_reason": str(result.get("termination_reason", "")),
				"state_after_first_turn": (result.get("state_after_first_turn", {}) as Dictionary).duplicate(true),
			}
			branch_rows.append(branch_record)
			if not bool(result.get("labeled", false)):
				branch_unlabeled += 1
				continue
			branches.append({"candidate_index": candidate_index, "result": result})

		var source: Dictionary = {}
		var source_variant: Variant = decision.get("source", {})
		if source_variant is Dictionary:
			source = (source_variant as Dictionary).duplicate(true)
		var priority_reasons: Array = (reasons_by_key.get(key, []) as Array).duplicate(true)
		if priority_reasons.is_empty():
			priority_reasons.append("family_diverse_fallback")

		for left_index: int in range(branches.size()):
			for right_index: int in range(left_index + 1, branches.size()):
				var left: Dictionary = branches[left_index] as Dictionary
				var right: Dictionary = branches[right_index] as Dictionary
				var left_result: Dictionary = left.get("result", {}) as Dictionary
				var right_result: Dictionary = right.get("result", {}) as Dictionary
				var comparison: Dictionary = helper._compare_terminal_results(left_result, right_result)
				if not bool(comparison.get("preferred", false)):
					no_preference += 1
					continue
				var left_better: bool = bool(comparison.get("selected_better", false))
				var pair_kind: String = str(comparison.get("pair_kind", ""))
				var pair_weight: float = float(comparison.get("weight", 1.0))
				if pair_kind == "outcome":
					outcome_pairs += 1
				elif pair_kind == "faster_win":
					faster_win_pairs += 1
				var better: Dictionary = left_result if left_better else right_result
				var worse: Dictionary = right_result if left_better else left_result
				var better_candidate_index: int = int(left.get("candidate_index", -1)) if left_better else int(right.get("candidate_index", -1))
				var worse_candidate_index: int = int(right.get("candidate_index", -1)) if left_better else int(left.get("candidate_index", -1))
				pairs.append({
					"schema_version": PAIR_SCHEMA_VERSION,
					"game_id": str(decision.get("game_id", "")),
					"turn_index": int(decision.get("turn_index", 0)),
					"perspective_group": str(decision.get("perspective_group", "")),
					"opponent_group": str(decision.get("opponent_group", "")),
					"response_index": shared_response_index,
					"pair_kind": pair_kind,
					"weight": pair_weight,
					"better_candidate_index": better_candidate_index,
					"worse_candidate_index": worse_candidate_index,
					"better_state": (better.get("state_after_first_turn", {}) as Dictionary).duplicate(true),
					"worse_state": (worse.get("state_after_first_turn", {}) as Dictionary).duplicate(true),
					"better_outcome": float(better.get("perspective_outcome", 0.0)),
					"worse_outcome": float(worse.get("perspective_outcome", 0.0)),
					"better_turns_after_branch": int(better.get("turns_played_after_branch", 0)),
					"worse_turns_after_branch": int(worse.get("turns_played_after_branch", 0)),
					"better_leaf_terminal": bool(better.get("leaf_terminal", false)),
					"worse_leaf_terminal": bool(worse.get("leaf_terminal", false)),
					"priority_reasons": priority_reasons.duplicate(true),
					"source": source,
				})

	var manifest: Dictionary = {
		"manifest_schema_version": MANIFEST_SCHEMA_VERSION,
		"pair_schema_version": PAIR_SCHEMA_VERSION,
		"source_decisions": "search_decisions.jsonl",
		"source_rejected_continuations": "rejected_continuations.jsonl",
		"pair_file": "ranking_pairs.jsonl",
		"branch_file": "sibling_branches.jsonl",
		"decisions_available": descriptors.size(),
		"decisions_selected": selected_descriptors.size(),
		"max_decisions": max_decisions,
		"neural_priority_decisions": neural_priority_decisions,
		"selected_decisions_by_family": selected_by_family,
		"branch_continuations": branch_continuations,
		"branch_unlabeled": branch_unlabeled,
		"pairs_written": pairs.size(),
		"outcome_pairs": outcome_pairs,
		"faster_win_pairs": faster_win_pairs,
		"no_preference": no_preference,
		"invalid": invalid,
		"outcome_pair_weight": OUTCOME_PAIR_WEIGHT,
		"faster_win_pair_weight": FASTER_WIN_PAIR_WEIGHT,
		"continuation_policy": "handwritten_greedy",
		"same_opponent_response": true,
		"all_candidate_siblings": true,
		"family_diverse_selection": true,
		"loss_vs_loss_pairs": false,
	}
	var ok: bool = _write_text(pairs_path, _to_jsonl(pairs))
	ok = _write_text(branches_path, _to_jsonl(branch_rows)) and ok
	ok = _write_text(manifest_path, JSON.stringify(manifest, "  ") + "\n") and ok
	print("[sibling-pairs] decisions=%d/%d neural_priority=%d branches=%d pairs=%d outcome=%d faster_win=%d unlabeled=%d no_preference=%d invalid=%d families=%s" % [
		selected_descriptors.size(),
		descriptors.size(),
		neural_priority_decisions,
		branch_continuations,
		pairs.size(),
		outcome_pairs,
		faster_win_pairs,
		branch_unlabeled,
		no_preference,
		invalid,
		str(selected_by_family),
	])
	helper.queue_free()
	get_tree().quit(0 if ok and invalid == 0 and pairs.size() > 0 else 1)


func _select_family_diverse(descriptors: Array, max_decisions: int) -> Array:
	var by_family: Dictionary = {}
	for descriptor_variant: Variant in descriptors:
		var descriptor: Dictionary = descriptor_variant as Dictionary
		var family: String = str(descriptor.get("family", "unknown"))
		if not by_family.has(family):
			by_family[family] = []
		(by_family[family] as Array).append(descriptor)
	for family_variant: Variant in by_family.keys():
		var family: String = str(family_variant)
		(by_family[family] as Array).sort_custom(_descriptor_before)

	var families: Array = by_family.keys()
	families.sort_custom(func(a: Variant, b: Variant) -> bool:
		var a_rows: Array = by_family[a] as Array
		var b_rows: Array = by_family[b] as Array
		return _descriptor_before(a_rows[0] as Dictionary, b_rows[0] as Dictionary)
	)
	var selected: Array = []
	var used: Dictionary = {}
	# First pass guarantees broad family coverage before spending extra budget on
	# repeated decisions from the strongest disagreement families.
	for family_variant: Variant in families:
		if selected.size() >= max_decisions:
			break
		var family_rows: Array = by_family[family_variant] as Array
		if family_rows.is_empty():
			continue
		var descriptor: Dictionary = family_rows[0] as Dictionary
		selected.append(descriptor)
		used[str(descriptor.get("key", ""))] = true

	var all_sorted: Array = descriptors.duplicate(true)
	all_sorted.sort_custom(_descriptor_before)
	for descriptor_variant: Variant in all_sorted:
		if selected.size() >= max_decisions:
			break
		var descriptor: Dictionary = descriptor_variant as Dictionary
		var key: String = str(descriptor.get("key", ""))
		if used.has(key):
			continue
		selected.append(descriptor)
		used[key] = true
	return selected


func _descriptor_before(a: Dictionary, b: Dictionary) -> bool:
	var a_hit: bool = bool(a.get("neural_priority_hit", false))
	var b_hit: bool = bool(b.get("neural_priority_hit", false))
	if a_hit != b_hit:
		return a_hit
	var a_score: float = float(a.get("priority_score", 0.0))
	var b_score: float = float(b.get("priority_score", 0.0))
	if not is_equal_approx(a_score, b_score):
		return a_score > b_score
	return str(a.get("key", "")) < str(b.get("key", ""))


func _decision_fallback_priority(decision: Dictionary) -> float:
	var candidates_variant: Variant = decision.get("candidates", [])
	if not (candidates_variant is Array):
		return 0.0
	var candidates: Array = candidates_variant as Array
	var initialized: bool = false
	var low: float = 0.0
	var high: float = 0.0
	for candidate_variant: Variant in candidates:
		if not (candidate_variant is Dictionary):
			continue
		var candidate: Dictionary = candidate_variant as Dictionary
		var score: float = float(candidate.get("handwritten_worst_case_score", 0.0))
		if not initialized:
			initialized = true
			low = score
			high = score
		else:
			low = minf(low, score)
			high = maxf(high, score)
	return absf(high - low)


func _shared_response_index(decision: Dictionary) -> int:
	var candidates_variant: Variant = decision.get("candidates", [])
	if not (candidates_variant is Array):
		return -1
	var candidates: Array = candidates_variant as Array
	var played_index: int = int(decision.get("selected_candidate_index", -1))
	if played_index < 0 or played_index >= candidates.size():
		return -1
	var candidate_variant: Variant = candidates[played_index]
	if not (candidate_variant is Dictionary):
		return -1
	var candidate: Dictionary = candidate_variant as Dictionary
	var initialized: bool = false
	var worst_score: float = 0.0
	var worst_index: int = -1
	for response_variant: Variant in candidate.get("responses", []):
		if not (response_variant is Dictionary):
			continue
		var response: Dictionary = response_variant as Dictionary
		var evaluation_variant: Variant = response.get("handwritten_evaluation", {})
		if not (evaluation_variant is Dictionary):
			continue
		var score: float = float((evaluation_variant as Dictionary).get("total", 0.0))
		if not initialized or score < worst_score:
			initialized = true
			worst_score = score
			worst_index = int(response.get("response_index", -1))
	return worst_index


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
