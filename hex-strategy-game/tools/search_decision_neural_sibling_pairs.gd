extends Node
## Build same-response sibling ranking pairs under the current neural policy.
##
## The existing dense sibling dataset labels candidate branches by handing the
## remainder of the game to handwritten-vs-handwritten play. This companion pass
## uses neural-vs-handwritten continuation instead, matching Arena deployment for
## the perspective being trained.

const PolicyContinuation = preload("res://tools/policy_continuation.gd")
const PureStateNeuralEvaluator = preload("res://src/simulation/pure_state_neural_evaluator.gd")

const PAIR_SCHEMA_VERSION := 2
const MANIFEST_SCHEMA_VERSION := 1
const DEFAULT_MAX_DECISIONS := 24


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	var args: Dictionary = _parse_cmdline_kv()
	var out_dir: String = str(args.get("out", "user://self_play_dataset"))
	var abs_out: String = ProjectSettings.globalize_path(out_dir)
	var checkpoint: String = str(args.get("neural-checkpoint", ""))
	var max_decisions: int = maxi(1, int(args.get("max-decisions", DEFAULT_MAX_DECISIONS)))
	var continuation_turn_cap: int = maxi(0, int(args.get("continuation-turn-cap", 0)))
	if checkpoint.is_empty():
		push_error("--neural-checkpoint is required")
		get_tree().quit(1)
		return

	var decisions_variant: Variant = _read_jsonl(abs_out.path_join("search_decisions.jsonl"))
	var rejected_variant: Variant = _read_jsonl(abs_out.path_join("rejected_continuations.jsonl"))
	if decisions_variant == null or rejected_variant == null:
		get_tree().quit(1)
		return
	var decisions: Array = decisions_variant as Array
	var rejected_rows: Array = rejected_variant as Array

	var neural_priority_by_key: Dictionary = {}
	for row_variant: Variant in rejected_rows:
		if not (row_variant is Dictionary):
			continue
		var row: Dictionary = row_variant as Dictionary
		var key: String = _continuation_decision_key(row)
		neural_priority_by_key[key] = maxf(
			float(neural_priority_by_key.get(key, 0.0)),
			float(row.get("priority_score", 0.0))
		)

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
		var neural_priority: float = float(neural_priority_by_key.get(key, 0.0))
		var fallback_priority: float = _decision_fallback_priority(decision)
		descriptors.append({
			"key": key,
			"family": str(source.get("base_scenario_id", decision.get("scenario_id", "unknown"))),
			"neural_priority": neural_priority,
			"fallback_priority": fallback_priority,
			"priority_score": neural_priority + fallback_priority,
			"neural_priority_hit": neural_priority_by_key.has(key),
		})

	var selected_descriptors: Array = _select_family_diverse(descriptors, max_decisions)
	var helper = PolicyContinuation.new()
	var pairs: Array = []
	var branches_out: Array = []
	var selected_by_family: Dictionary = {}
	var invalid: int = 0
	var unlabeled: int = 0
	var no_preference: int = 0
	var outcome_pairs: int = 0
	var faster_win_pairs: int = 0
	var branch_continuations: int = 0

	for descriptor_variant: Variant in selected_descriptors:
		var descriptor: Dictionary = descriptor_variant as Dictionary
		var key: String = str(descriptor.get("key", ""))
		if not decision_by_key.has(key):
			invalid += 1
			continue
		var decision: Dictionary = decision_by_key[key] as Dictionary
		var family: String = str(descriptor.get("family", "unknown"))
		selected_by_family[family] = int(selected_by_family.get(family, 0)) + 1
		var response_index: int = _shared_response_index(decision)
		if response_index < 0:
			invalid += 1
			continue
		var candidates: Array = decision.get("candidates", []) as Array
		var labeled_branches: Array = []
		for candidate_index: int in range(candidates.size()):
			branch_continuations += 1
			var result: Dictionary = helper.continue_candidate(
				decision,
				candidate_index,
				response_index,
				continuation_turn_cap,
				PolicyContinuation.POLICY_NEURAL_VS_HANDWRITTEN,
				checkpoint
			)
			if not bool(result.get("valid", false)):
				invalid += 1
				continue
			branches_out.append({
				"game_id": str(decision.get("game_id", "")),
				"turn_index": int(decision.get("turn_index", 0)),
				"perspective_group": str(decision.get("perspective_group", "")),
				"family": family,
				"candidate_index": candidate_index,
				"response_index": response_index,
				"continuation_policy": PolicyContinuation.POLICY_NEURAL_VS_HANDWRITTEN,
				"labeled": bool(result.get("labeled", false)),
				"winner": str(result.get("winner", "")),
				"perspective_outcome": float(result.get("perspective_outcome", 0.0)),
				"turns_played_after_branch": int(result.get("turns_played_after_branch", 0)),
			})
			if not bool(result.get("labeled", false)):
				unlabeled += 1
				continue
			labeled_branches.append({
				"candidate_index": candidate_index,
				"result": result,
			})

		var source: Dictionary = {}
		var source_variant: Variant = decision.get("source", {})
		if source_variant is Dictionary:
			source = (source_variant as Dictionary).duplicate(true)
		source["continuation_policy"] = PolicyContinuation.POLICY_NEURAL_VS_HANDWRITTEN

		for left_index: int in range(labeled_branches.size()):
			for right_index: int in range(left_index + 1, labeled_branches.size()):
				var left: Dictionary = labeled_branches[left_index] as Dictionary
				var right: Dictionary = labeled_branches[right_index] as Dictionary
				var left_result: Dictionary = left.get("result", {}) as Dictionary
				var right_result: Dictionary = right.get("result", {}) as Dictionary
				var comparison: Dictionary = helper.compare_terminal_results(left_result, right_result)
				if not bool(comparison.get("preferred", false)):
					no_preference += 1
					continue
				var left_better: bool = bool(comparison.get("left_better", false))
				var better: Dictionary = left_result if left_better else right_result
				var worse: Dictionary = right_result if left_better else left_result
				var pair_kind: String = str(comparison.get("pair_kind", ""))
				if pair_kind == "outcome":
					outcome_pairs += 1
				elif pair_kind == "faster_win":
					faster_win_pairs += 1
				pairs.append({
					"schema_version": PAIR_SCHEMA_VERSION,
					"game_id": str(decision.get("game_id", "")),
					"turn_index": int(decision.get("turn_index", 0)),
					"perspective_group": str(decision.get("perspective_group", "")),
					"opponent_group": str(decision.get("opponent_group", "")),
					"response_index": response_index,
					"pair_kind": pair_kind,
					"weight": float(comparison.get("weight", 1.0)),
					"better_candidate_index": int(left.get("candidate_index", -1)) if left_better else int(right.get("candidate_index", -1)),
					"worse_candidate_index": int(right.get("candidate_index", -1)) if left_better else int(left.get("candidate_index", -1)),
					"better_state": (better.get("state_after_first_turn", {}) as Dictionary).duplicate(true),
					"worse_state": (worse.get("state_after_first_turn", {}) as Dictionary).duplicate(true),
					"better_outcome": float(better.get("perspective_outcome", 0.0)),
					"worse_outcome": float(worse.get("perspective_outcome", 0.0)),
					"better_turns_after_branch": int(better.get("turns_played_after_branch", 0)),
					"worse_turns_after_branch": int(worse.get("turns_played_after_branch", 0)),
					"better_leaf_terminal": bool(better.get("leaf_terminal", false)),
					"worse_leaf_terminal": bool(worse.get("leaf_terminal", false)),
					"continuation_policy": PolicyContinuation.POLICY_NEURAL_VS_HANDWRITTEN,
					"priority_reasons": ["policy_distribution_correction"],
					"source": source,
				})

	var manifest := {
		"manifest_schema_version": MANIFEST_SCHEMA_VERSION,
		"pair_schema_version": PAIR_SCHEMA_VERSION,
		"continuation_policy": PolicyContinuation.POLICY_NEURAL_VS_HANDWRITTEN,
		"decisions_available": descriptors.size(),
		"decisions_selected": selected_descriptors.size(),
		"max_decisions": max_decisions,
		"selected_decisions_by_family": selected_by_family,
		"branch_continuations": branch_continuations,
		"branch_unlabeled": unlabeled,
		"pairs_written": pairs.size(),
		"outcome_pairs": outcome_pairs,
		"faster_win_pairs": faster_win_pairs,
		"no_preference": no_preference,
		"invalid": invalid,
		"same_opponent_response": true,
		"all_candidate_siblings": true,
		"family_diverse_selection": true,
		"loss_vs_loss_pairs": false,
	}
	var ok: bool = _write_text(abs_out.path_join("neural_ranking_pairs.jsonl"), _to_jsonl(pairs))
	ok = _write_text(abs_out.path_join("neural_sibling_branches.jsonl"), _to_jsonl(branches_out)) and ok
	ok = _write_text(
		abs_out.path_join("neural_ranking_pairs_manifest.json"),
		JSON.stringify(manifest, "  ") + "\n"
	) and ok
	print("[neural-sibling-pairs] decisions=%d/%d branches=%d pairs=%d outcome=%d faster_win=%d unlabeled=%d invalid=%d families=%s" % [
		selected_descriptors.size(),
		descriptors.size(),
		branch_continuations,
		pairs.size(),
		outcome_pairs,
		faster_win_pairs,
		unlabeled,
		invalid,
		str(selected_by_family),
	])
	PureStateNeuralEvaluator.shutdown()
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
		(by_family[family_variant] as Array).sort_custom(_descriptor_before)

	var families: Array = by_family.keys()
	families.sort_custom(func(a: Variant, b: Variant) -> bool:
		var a_rows: Array = by_family[a] as Array
		var b_rows: Array = by_family[b] as Array
		return _descriptor_before(a_rows[0] as Dictionary, b_rows[0] as Dictionary)
	)
	var selected: Array = []
	var used: Dictionary = {}
	for family_variant: Variant in families:
		if selected.size() >= max_decisions:
			break
		var rows: Array = by_family[family_variant] as Array
		if rows.is_empty():
			continue
		var descriptor: Dictionary = rows[0] as Dictionary
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
	var initialized: bool = false
	var low: float = 0.0
	var high: float = 0.0
	for candidate_variant: Variant in candidates_variant as Array:
		if not (candidate_variant is Dictionary):
			continue
		var score: float = float((candidate_variant as Dictionary).get("handwritten_worst_case_score", 0.0))
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
	var worst_score: float = 0.0
	var worst_index: int = -1
	var initialized: bool = false
	for response_variant: Variant in (candidate_variant as Dictionary).get("responses", []):
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
		if arg.begins_with("--"):
			arg = arg.substr(2)
		if arg.contains("="):
			var parts: PackedStringArray = arg.split("=", true, 1)
			result[parts[0]] = parts[1]
		elif not arg.is_empty():
			var next_value: String = ""
			if i + 1 < raw.size() and not str(raw[i + 1]).begins_with("-"):
				next_value = str(raw[i + 1]).strip_edges()
				i += 1
			result[arg] = next_value if not next_value.is_empty() else "true"
		i += 1
	return result
