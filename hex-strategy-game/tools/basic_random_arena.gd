extends Node
## Mirrored held-out arena for randomized radius-one Marine-vs-Zergling starts.

const GameplayAI = preload("res://src/battle/ai/gameplay_ai.gd")
const PureStateBasicRandomSuite = preload("res://src/simulation/pure_state_basic_random_suite.gd")
const PureStateGameRollout = preload("res://src/simulation/pure_state_game_rollout.gd")
const PureStateNeuralEvaluator = preload("res://src/simulation/pure_state_neural_evaluator.gd")
const DeterministicShard = preload("res://tools/deterministic_shard.gd")

const MANIFEST_SCHEMA_VERSION := 1


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	var args := _parse_cmdline_kv()
	var mode := str(args.get("mode", "random"))
	var checkpoint := str(args.get("checkpoint", ""))
	var out_dir := str(args.get("out", "user://basic_random_arena"))
	var rules_version := str(args.get("rules-version", "unknown"))
	var pair_count := int(args.get("pair-count", str(PureStateBasicRandomSuite.DEFAULT_EVALUATION_PAIRS)))
	var shard_index := int(args.get("shard-index", "0"))
	var shard_count := int(args.get("shard-count", "1"))
	var decision_time_budget_ms := float(args.get("decision-time-budget-ms", "5000"))
	var runner_type := str(args.get("runner-type", OS.get_name()))
	var learned_proposals := _parse_bool(args.get("learned-proposals", "false"))
	if checkpoint.is_empty():
		push_error("Arena requires --checkpoint")
		get_tree().quit(1)
		return
	if mode not in ["random", "counterfactual"]:
		push_error("Unknown arena mode: %s" % mode)
		get_tree().quit(1)
		return
	if shard_count <= 0 or shard_index < 0 or shard_index >= shard_count:
		push_error("Invalid shard %d/%d" % [shard_index, shard_count])
		get_tree().quit(1)
		return

	var all_jobs := PureStateBasicRandomSuite.evaluation_pair_jobs(pair_count) if mode == "random" else PureStateBasicRandomSuite.counterfactual_pair_jobs()
	var jobs := DeterministicShard.filter_grouped_jobs_round_robin(all_jobs, "pair_id", shard_index, shard_count)
	var champion_settings := GameplayAI.handwritten_settings(
		PureStateBasicRandomSuite.MAX_ACTIONS_PER_UNIT,
		PureStateBasicRandomSuite.OWN_MAX_PLANS,
		PureStateBasicRandomSuite.MAX_ACTIONS_PER_UNIT,
		PureStateBasicRandomSuite.OPPONENT_MAX_PLANS
	)
	var challenger_settings := GameplayAI.neural_settings(
		PureStateBasicRandomSuite.MAX_ACTIONS_PER_UNIT,
		PureStateBasicRandomSuite.OWN_MAX_PLANS,
		PureStateBasicRandomSuite.MAX_ACTIONS_PER_UNIT,
		PureStateBasicRandomSuite.OPPONENT_MAX_PLANS,
		checkpoint,
		{"learned_proposals": learned_proposals}
	)
	for settings in [champion_settings, challenger_settings]:
		var evaluator_settings: Dictionary = settings.get("evaluator_settings", {}).duplicate(true)
		evaluator_settings["decision_time_budget_ms"] = decision_time_budget_ms
		settings["evaluator_settings"] = evaluator_settings

	var abs_out := ProjectSettings.globalize_path(out_dir)
	if DirAccess.make_dir_recursive_absolute(abs_out) != OK:
		push_error("Unable to create arena output directory: %s" % abs_out)
		get_tree().quit(1)
		return

	var game_summaries: Array = []
	var traces: Array = []
	var counts := {"challenger": 0, "champion": 0, "draw": 0, "unresolved": 0, "failed": 0}
	var termination_counts: Dictionary = {}
	for job_variant in jobs:
		if not (job_variant is Dictionary):
			counts["failed"] = int(counts["failed"]) + 1
			continue
		var job: Dictionary = job_variant
		var challenger_group := str(job.get("challenger_group", ""))
		var champion_group := str(job.get("champion_group", ""))
		var terran_settings := challenger_settings if challenger_group == "terran" else champion_settings
		var zerg_settings := challenger_settings if challenger_group == "zerg" else champion_settings
		var result := PureStateGameRollout.play_game_with_settings(
			job.get("state", {}) as Dictionary,
			"terran",
			"zerg",
			terran_settings,
			zerg_settings,
			int(job.get("max_turns", PureStateBasicRandomSuite.MAX_TURNS)),
			false,
			str(job.get("turn_limit_winner", ""))
		)
		var winner_agent := _winner_agent(
			bool(result.get("valid", false)),
			str(result.get("status", "")),
			str(result.get("winner", "")),
			challenger_group,
			champion_group
		)
		counts[winner_agent] = int(counts.get(winner_agent, 0)) + 1
		var termination_reason := str(result.get("termination_reason", ""))
		termination_counts[termination_reason] = int(termination_counts.get(termination_reason, 0)) + 1
		var search_metrics: Dictionary = result.get("search_metrics", {})
		var challenger_search: Dictionary = search_metrics.get(challenger_group, {})
		var champion_search: Dictionary = search_metrics.get(champion_group, {})
		var summary := {
			"pair_id": str(job.get("pair_id", "")),
			"game_id": str(job.get("game_id", "")),
			"scenario_seed": int(job.get("scenario_seed", 0)),
			"base_scenario_id": str(job.get("base_scenario_id", "")),
			"rotation_steps": int(job.get("rotation_steps", 0)),
			"variation_seed": 0,
			"variation_passes": 0,
			"map_profile": PureStateBasicRandomSuite.MAP_PROFILE,
			"hex_radius": 1,
			"marines": int(job.get("marines", 0)),
			"zerglings": int(job.get("zerglings", 0)),
			"challenger_group": challenger_group,
			"champion_group": champion_group,
			"max_turns": int(job.get("max_turns", 0)),
			"valid": bool(result.get("valid", false)),
			"status": str(result.get("status", "")),
			"winner_group": str(result.get("winner", "")),
			"winner_agent": winner_agent,
			"termination_reason": termination_reason,
			"turns_played": int(result.get("turns_played", 0)),
			"max_non_progress_streak": int(result.get("max_non_progress_streak", 0)),
			"challenger_search": challenger_search.duplicate(true),
			"champion_search": champion_search.duplicate(true),
			"final_alive_counts": (result.get("final_alive_counts", {}) as Dictionary).duplicate(true),
			"command_hexes": (result.get("command_hexes", {}) as Dictionary).duplicate(true),
		}
		game_summaries.append(summary)
		traces.append({
			"game_id": str(job.get("game_id", "")),
			"pair_id": str(job.get("pair_id", "")),
			"winner_agent": winner_agent,
			"history": (result.get("history", []) as Array).duplicate(true),
		})
		print("[basic-random-arena] %s mode=%s m=%d z=%d r=%d challenger=%s result=%s/%s" % [
			str(job.get("game_id", "")), mode, int(job.get("marines", 0)), int(job.get("zerglings", 0)),
			int(job.get("rotation_steps", 0)), challenger_group, winner_agent, termination_reason
		])

	var manifest := {
		"manifest_schema_version": MANIFEST_SCHEMA_VERSION,
		"arena_suite_version": PureStateBasicRandomSuite.VERSION,
		"preset": "basic_random_holdout" if mode == "random" else "basic_counterfactual",
		"seed_base": PureStateBasicRandomSuite.EVALUATION_SEED_BASE if mode == "random" else 0,
		"rules_version": rules_version,
		"decision_time_budget_ms": decision_time_budget_ms,
		"runner_type": runner_type,
		"checkpoint_sha256": FileAccess.get_sha256(checkpoint),
		"map_profile": PureStateBasicRandomSuite.MAP_PROFILE,
		"champion_profile": "balanced",
		"challenger_profile": "balanced",
		"champion_evaluator": "handwritten",
		"challenger_evaluator": "neural",
		"learned_proposals": learned_proposals,
		"champion_settings": champion_settings,
		"challenger_settings": challenger_settings,
		"preset_games": all_jobs.size(),
		"preset_pairs": all_jobs.size() / 2,
		"shard_index": shard_index,
		"shard_count": shard_count,
		"shard_key": "pair_id_round_robin",
		"games_requested": jobs.size(),
		"pairs_requested": jobs.size() / 2,
		"counts": counts,
		"termination_counts": termination_counts,
		"games": game_summaries,
	}
	var ok := _write_json(out_dir.path_join("manifest.json"), manifest)
	ok = _write_jsonl(out_dir.path_join("traces.jsonl"), traces) and ok
	print("[basic-random-arena] summary mode=%s games=%d pairs=%d learned_proposals=%s counts=%s" % [mode, game_summaries.size(), game_summaries.size() / 2, str(learned_proposals), str(counts)])
	PureStateNeuralEvaluator.shutdown()
	get_tree().quit(0 if ok and int(counts.get("failed", 0)) == 0 else 1)


func _winner_agent(valid: bool, status: String, winner_group: String, challenger_group: String, champion_group: String) -> String:
	if not valid:
		return "failed"
	if status == "turn_limit":
		return "unresolved"
	if winner_group.is_empty():
		return "draw"
	if winner_group == challenger_group:
		return "challenger"
	if winner_group == champion_group:
		return "champion"
	return "failed"


func _parse_bool(value: Variant) -> bool:
	return str(value).strip_edges().to_lower() in ["1", "true", "yes", "on"]


func _write_json(path: String, value: Variant) -> bool:
	return _write_text(path, JSON.stringify(value, "  ") + "\n")


func _write_jsonl(path: String, rows: Array) -> bool:
	var lines := PackedStringArray()
	for row in rows:
		lines.append(JSON.stringify(row))
	return _write_text(path, "\n".join(lines) + ("\n" if not lines.is_empty() else ""))


func _write_text(path: String, content: String) -> bool:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_error("Unable to write %s" % ProjectSettings.globalize_path(path))
		return false
	file.store_string(content)
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
		if arg.begins_with("--"):
			arg = arg.substr(2)
		if arg.contains("="):
			var parts := arg.split("=", true, 1)
			result[parts[0]] = parts[1]
		elif not arg.is_empty():
			var next_value := ""
			if i + 1 < raw.size() and not str(raw[i + 1]).begins_with("-"):
				next_value = str(raw[i + 1]).strip_edges()
				i += 1
			result[arg] = next_value if not next_value.is_empty() else "true"
		i += 1
	return result
