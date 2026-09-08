extends Node
## Replays the frozen human Arena holdout and measures whether production
## opponent-response search can represent the human responses that exploited it.

const ArenaPlaytestScenario = preload("res://src/battle/arena_playtest_scenario.gd")
const PureStateArenaSuite = preload("res://src/simulation/pure_state_arena_suite.gd")
const PureStatePlans = preload("res://src/simulation/pure_state_plans.gd")
const PureStatePlanIntents = preload("res://src/simulation/pure_state_plan_intents.gd")
const PureStateOpponentResponseSearch = preload("res://src/simulation/pure_state_opponent_response_search.gd")
const PureStateSimulator = preload("res://src/simulation/pure_state_simulator.gd")
const PureStateEvaluator = preload("res://src/simulation/pure_state_evaluator.gd")
const PureStateCandidateOracleRecall = preload("res://src/simulation/pure_state_candidate_oracle_recall.gd")

const BENCHMARK_ID := "human_playtest_v1"
const DEFAULT_INPUT := "res://tests/fixtures/human_playtest_v1.jsonl"
const DEFAULT_REGRET_TOLERANCE := 0.10


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	var args := _parse_cmdline_kv()
	var quality := str(args.get("quality", "adversarial"))
	var max_decisions := int(args.get("max-decisions", "0"))
	var out_dir := str(args.get("out", "user://human_playtest_benchmark"))
	var regret_tolerance := maxf(0.0, float(args.get("regret-tolerance", str(DEFAULT_REGRET_TOLERANCE))))
	var games_variant: Variant = _read_jsonl(str(args.get("input-jsonl", DEFAULT_INPUT)))
	if games_variant == null:
		get_tree().quit(1)
		return

	var games: Array = games_variant as Array
	var decisions: Array = []
	var failures: Array = []
	var selected_count := 0
	for game_variant in games:
		if not (game_variant is Dictionary):
			continue
		var game: Dictionary = game_variant
		if quality != "all" and str(game.get("response_quality", "")) != quality:
			continue
		var profile_name := str(game.get("ai_agent_profile", "balanced"))
		var profile: Dictionary = PureStateArenaSuite.AGENT_PROFILES.get(profile_name, {})
		var scenario := ArenaPlaytestScenario.build(
			int(game.get("scenario_seed", 0)),
			str(game.get("human_group", "")),
			profile_name,
			str(game.get("map_profile", PureStateArenaSuite.DEFAULT_MAP_PROFILE)),
			str(game.get("preset", "fast")),
			ArenaPlaytestScenario.AI_VARIANT_HANDWRITTEN
		)
		var state: Dictionary = ((scenario.get("arena_playtest", {}) as Dictionary).get("initial_state", {}) as Dictionary).duplicate(true)
		if profile.is_empty() or state.is_empty():
			failures.append({"game_id": game.get("game_id", ""), "error": "could_not_rebuild_game"})
			continue

		for turn_variant in game.get("turns", []):
			if not (turn_variant is Dictionary):
				continue
			if max_decisions > 0 and selected_count >= max_decisions:
				break
			var turn: Dictionary = turn_variant
			var human_actions: Array = (turn.get("human_actions", []) as Array).duplicate(true)
			var recorded_ai_actions: Array = (turn.get("recorded_ai_actions", []) as Array).duplicate(true)
			var result := _evaluate_turn(state, game, turn, human_actions, recorded_ai_actions, profile, regret_tolerance)
			decisions.append(result)
			selected_count += 1
			if not bool(result.get("valid", false)):
				failures.append({"decision_id": result.get("decision_id", ""), "error": result.get("error", "unknown")})
			else:
				print("[human-playtest] %s source=%s final=%s regret=%.3f class=%s" % [
					result.get("decision_id", ""),
					result.get("human_response_source_recalled", false),
					result.get("human_response_recalled", false),
					result.get("actual_response_regret", 0.0),
					result.get("failure_classification", ""),
				])

			# Advance from the same simultaneous actions that actually occurred so the
			# next recorded human response starts from its original game trajectory.
			var replay_actions: Dictionary = {}
			replay_actions[str(game.get("human_group", ""))] = human_actions
			replay_actions[str(game.get("ai_group", ""))] = recorded_ai_actions
			var replay := PureStateSimulator.simulate_turn(state, replay_actions)
			state = (replay.get("next_state", {}) as Dictionary).duplicate(true)
		if max_decisions > 0 and selected_count >= max_decisions:
			break

	if decisions.is_empty():
		push_error("No human-playtest decisions selected")
		get_tree().quit(1)
		return
	var summary := _summarize(decisions)
	var manifest := {
		"benchmark_id": BENCHMARK_ID,
		"benchmark_version": 1,
		"split": "evaluation_holdout",
		"training_allowed": false,
		"quality_filter": quality,
		"regret_tolerance": regret_tolerance,
		"decisions_requested": decisions.size(),
		"decisions_failed": failures.size(),
		"summary": summary,
		"failures": failures,
		"semantics": {
			"human_is_oracle": false,
			"response_recall": "exact recorded human plan is retained by production opponent-response generation",
			"regret": "selected-AI value gap versus the best production AI candidate when all candidates face the same recorded human response",
			"holdout": "human_playtest_v1 is evaluation-only; collect separate human games for training",
		},
	}
	var abs_out := ProjectSettings.globalize_path(out_dir)
	DirAccess.make_dir_recursive_absolute(abs_out)
	var ok := _write_text(out_dir.path_join("decisions.jsonl"), _to_jsonl(decisions))
	ok = _write_text(out_dir.path_join("manifest.json"), JSON.stringify(manifest, "  ") + "\n") and ok
	print("[human-playtest] summary %s" % JSON.stringify(summary))
	get_tree().quit(0 if ok and failures.is_empty() else 1)


func _evaluate_turn(
	state: Dictionary,
	game: Dictionary,
	turn: Dictionary,
	human_actions: Array,
	recorded_ai_actions: Array,
	profile: Dictionary,
	regret_tolerance: float
) -> Dictionary:
	var ai_group := str(game.get("ai_group", ""))
	var human_group := str(game.get("human_group", ""))
	var max_actions := maxi(1, int(profile.get("max_actions_per_unit", 8)))
	var own_max_plans := maxi(1, int(profile.get("own_max_plans", 4)))
	var opponent_max_plans := maxi(1, int(profile.get("opponent_max_plans", 4)))
	var decision_id := "%s|turn_%03d|%s" % [game.get("game_id", "game"), int(turn.get("turn_index", 0)), ai_group]
	var search := PureStateOpponentResponseSearch.search(
		state, ai_group, human_group,
		max_actions, own_max_plans, max_actions, opponent_max_plans
	)
	if not bool(search.get("valid", false)):
		return {"valid": false, "decision_id": decision_id, "error": "production_search_failed"}

	var pool_limit := maxi(opponent_max_plans, opponent_max_plans * PureStateOpponentResponseSearch.SOURCE_POOL_MULTIPLIER)
	var source_pool := PureStatePlans.get_candidate_plans(state, human_group, max_actions, pool_limit, true)
	var final_candidates := PureStatePlanIntents.select_opponent_candidates(state, human_group, source_pool, opponent_max_plans)
	var human_signature := PureStateCandidateOracleRecall.plan_signature(human_actions)
	var source_recalled := _has_signature(source_pool, human_signature)
	var final_recalled := _has_signature(final_candidates, human_signature)

	var selected_signature := PureStateCandidateOracleRecall.plan_signature(search.get("best_actions", []))
	var selected_score: Variant = null
	var best_score := -INF
	var best_actions: Array = []
	for candidate_variant in search.get("ranked_results", []):
		if not (candidate_variant is Dictionary):
			continue
		var candidate: Dictionary = candidate_variant
		var ai_actions: Array = (candidate.get("actions", []) as Array).duplicate(true)
		var submitted: Dictionary = {}
		submitted[ai_group] = ai_actions
		submitted[human_group] = human_actions
		var simulation := PureStateSimulator.simulate_turn(state, submitted)
		var breakdown := PureStateEvaluator.evaluate_breakdown(simulation.get("next_state", {}) as Dictionary, ai_group)
		if not bool(breakdown.get("valid", false)):
			return {"valid": false, "decision_id": decision_id, "error": "forced_response_evaluation_failed"}
		var score := float(breakdown.get("total", 0.0))
		var signature := PureStateCandidateOracleRecall.plan_signature(ai_actions)
		if signature == selected_signature:
			selected_score = score
		if score > best_score:
			best_score = score
			best_actions = ai_actions
	if selected_score == null:
		return {"valid": false, "decision_id": decision_id, "error": "selected_plan_not_scored"}

	var regret := maxf(0.0, best_score - float(selected_score))
	var consequential := regret > regret_tolerance and not is_equal_approx(regret, regret_tolerance)
	var classification := "robust_to_recorded_human_response"
	if not source_recalled:
		classification = "opponent_response_generation_miss"
	elif not final_recalled:
		classification = "opponent_response_selection_miss"
	elif consequential:
		classification = "ranking_failure_under_recalled_human_response"
	return {
		"valid": true,
		"decision_id": decision_id,
		"game_id": str(game.get("game_id", "")),
		"turn_index": int(turn.get("turn_index", 0)),
		"family": str(game.get("family", "")),
		"scenario_seed": int(game.get("scenario_seed", 0)),
		"response_quality": str(game.get("response_quality", "")),
		"human_response_source_recalled": source_recalled,
		"human_response_recalled": final_recalled,
		"human_plan_signature": human_signature,
		"opponent_source_candidate_count": source_pool.size(),
		"opponent_final_candidate_count": final_candidates.size(),
		"selected_plan_signature": selected_signature,
		"recorded_ai_plan_match": selected_signature == PureStateCandidateOracleRecall.plan_signature(recorded_ai_actions),
		"selected_score_against_human": float(selected_score),
		"best_score_against_human": best_score,
		"best_actions_against_human": best_actions,
		"actual_response_regret": regret,
		"selected_near_best_against_human": not consequential,
		"consequential_response_miss": consequential and not final_recalled,
		"failure_classification": classification,
	}


func _summarize(rows: Array) -> Dictionary:
	var valid_count := 0
	var source_recall := 0
	var final_recall := 0
	var near_best := 0
	var consequential_misses := 0
	var total_regret := 0.0
	var max_regret := 0.0
	var classifications: Dictionary = {}
	for row_variant in rows:
		if not (row_variant is Dictionary) or not bool((row_variant as Dictionary).get("valid", false)):
			continue
		var row: Dictionary = row_variant
		valid_count += 1
		if bool(row.get("human_response_source_recalled", false)):
			source_recall += 1
		if bool(row.get("human_response_recalled", false)):
			final_recall += 1
		if bool(row.get("selected_near_best_against_human", false)):
			near_best += 1
		if bool(row.get("consequential_response_miss", false)):
			consequential_misses += 1
		var regret := float(row.get("actual_response_regret", 0.0))
		total_regret += regret
		max_regret = maxf(max_regret, regret)
		var classification := str(row.get("failure_classification", "unknown"))
		classifications[classification] = int(classifications.get(classification, 0)) + 1
	return {
		"decision_count": valid_count,
		"human_response_source_recall_rate": float(source_recall) / float(valid_count) if valid_count > 0 else 0.0,
		"human_response_recall_rate": float(final_recall) / float(valid_count) if valid_count > 0 else 0.0,
		"selected_near_best_against_human_rate": float(near_best) / float(valid_count) if valid_count > 0 else 0.0,
		"consequential_response_miss_rate": float(consequential_misses) / float(valid_count) if valid_count > 0 else 0.0,
		"mean_actual_response_regret": total_regret / float(valid_count) if valid_count > 0 else 0.0,
		"max_actual_response_regret": max_regret,
		"failure_classification_counts": classifications,
	}


func _has_signature(candidates: Array, signature: String) -> bool:
	for candidate_variant in candidates:
		if candidate_variant is Dictionary and PureStateCandidateOracleRecall.plan_signature((candidate_variant as Dictionary).get("actions", [])) == signature:
			return true
	return false


func _read_jsonl(path: String) -> Variant:
	var file := FileAccess.open(ProjectSettings.globalize_path(path), FileAccess.READ)
	if file == null:
		push_error("Cannot open human-playtest fixture: %s" % path)
		return null
	var rows: Array = []
	while not file.eof_reached():
		var line := file.get_line().strip_edges()
		if line.is_empty():
			continue
		var parsed: Variant = JSON.parse_string(line)
		if not (parsed is Dictionary):
			file.close()
			push_error("Invalid human-playtest JSONL")
			return null
		rows.append(parsed)
	file.close()
	return rows


func _to_jsonl(rows: Array) -> String:
	var lines: PackedStringArray = []
	for row_variant in rows:
		if row_variant is Dictionary:
			lines.append(JSON.stringify(row_variant))
	return "\n".join(lines) + "\n"


func _write_text(path: String, text: String) -> bool:
	var file := FileAccess.open(ProjectSettings.globalize_path(path), FileAccess.WRITE)
	if file == null:
		return false
	file.store_string(text)
	file.close()
	return true


func _parse_cmdline_kv() -> Dictionary:
	var result: Dictionary = {}
	var raw: PackedStringArray = OS.get_cmdline_user_args()
	var i := 0
	while i < raw.size():
		var arg := str(raw[i]).strip_edges()
		if arg.begins_with("--"):
			arg = arg.substr(2)
		if arg.contains("="):
			var parts := arg.split("=", true, 1)
			result[parts[0]] = parts[1]
		elif i + 1 < raw.size() and not str(raw[i + 1]).begins_with("-"):
			result[arg] = str(raw[i + 1])
			i += 1
		else:
			result[arg] = ""
		i += 1
	return result
