extends Node
## Headless seeded AI-vs-AI arena runner.
##
## Example:
## godot --headless --path . res://tools/ai_arena.tscn -- \
##   --preset=fast --champion-profile=fast --challenger-profile=fast \
##   --champion-evaluator=handwritten --challenger-evaluator=neural \
##   --out=user://ai_arena --shard-index=0 --shard-count=4

const PureStateArenaSuite = preload("res://src/simulation/pure_state_arena_suite.gd")
const PureStateGameRollout = preload("res://src/simulation/pure_state_game_rollout.gd")
const PureStateNeuralEvaluator = preload("res://src/simulation/pure_state_neural_evaluator.gd")
const DeterministicShard = preload("res://tools/deterministic_shard.gd")

const MANIFEST_SCHEMA_VERSION := 1


func _ready() -> void:
	call_deferred("_run_arena")


func _run_arena() -> void:
	var args := _parse_cmdline_kv()
	var preset := str(args.get("preset", "fast"))
	var map_profile := str(args.get("map-profile", PureStateArenaSuite.DEFAULT_MAP_PROFILE))
	var champion_profile := str(args.get("champion-profile", "fast"))
	var challenger_profile := str(args.get("challenger-profile", "fast"))
	var champion_evaluator := str(args.get("champion-evaluator", "handwritten"))
	var challenger_evaluator := str(args.get("challenger-evaluator", "handwritten"))
	var seed_base := int(args.get("seed-base", str(PureStateArenaSuite.DEFAULT_SEED_BASE)))
	var shard_index := int(args.get("shard-index", "0"))
	var shard_count := int(args.get("shard-count", "1"))
	var out_dir := str(args.get("out", "user://ai_arena"))
	var rules_version := str(args.get("rules-version", "unknown"))
	var runner_type := str(args.get("runner-type", OS.get_name()))

	if shard_count <= 0 or shard_index < 0 or shard_index >= shard_count:
		push_error("Invalid arena shard %d/%d" % [shard_index, shard_count])
		get_tree().quit(1)
		return
	if map_profile not in PureStateArenaSuite.available_map_profiles():
		push_error("Unknown arena map profile '%s'. Available: %s" % [map_profile, str(PureStateArenaSuite.available_map_profiles())])
		get_tree().quit(1)
		return
	var champion_settings := PureStateArenaSuite.agent_settings(champion_profile, champion_evaluator)
	var challenger_settings := PureStateArenaSuite.agent_settings(challenger_profile, challenger_evaluator)
	var decision_time_budget_ms := float(args.get("decision-time-budget-ms", "0"))
	for settings in [champion_settings, challenger_settings]:
		var evaluation: Dictionary = settings.get("evaluator_settings", {}).duplicate(true)
		evaluation["decision_time_budget_ms"] = decision_time_budget_ms
		if str(settings.get("evaluator", "")) == "neural" and args.has("checkpoint"):
			evaluation["checkpoint_path"] = str(args["checkpoint"])
		settings["evaluator_settings"] = evaluation
	if champion_settings.is_empty() or challenger_settings.is_empty():
		push_error(
			"Unknown arena agent config champion=%s/%s challenger=%s/%s" % [
				champion_profile,
				champion_evaluator,
				challenger_profile,
				challenger_evaluator,
			]
		)
		get_tree().quit(1)
		return

	var all_jobs := PureStateArenaSuite.get_preset(preset, seed_base, map_profile)
	if all_jobs.is_empty():
		push_error("Unknown or empty arena preset '%s'. Available: %s" % [preset, str(PureStateArenaSuite.available_presets())])
		get_tree().quit(1)
		return
	# Official arena presets have a stable source order. Assign complete mirrored
	# pairs round-robin so every worker gets the same number of pairs when the
	# preset divides evenly (fast: 2 pairs/worker; full: 4 pairs/worker).
	var jobs := DeterministicShard.filter_grouped_jobs_round_robin(
		all_jobs,
		"pair_id",
		shard_index,
		shard_count
	)
	print("[arena] map_profile=%s shard=%d/%d selected=%d/%d games by balanced pair order" % [map_profile, shard_index, shard_count, jobs.size(), all_jobs.size()])

	var abs_out := ProjectSettings.globalize_path(out_dir)
	if DirAccess.make_dir_recursive_absolute(abs_out) != OK:
		push_error("Unable to create arena output directory: %s" % abs_out)
		get_tree().quit(1)
		return

	var started_usec := Time.get_ticks_usec()
	var game_summaries: Array = []
	var traces: Array = []
	var counts := {"challenger": 0, "champion": 0, "draw": 0, "unresolved": 0, "failed": 0}
	var termination_counts: Dictionary = {}
	var total_turns := 0
	var challenger_elapsed_ms := 0.0
	var champion_elapsed_ms := 0.0
	var challenger_simulations := 0
	var champion_simulations := 0

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
			int(job.get("max_turns", 10)),
			false
		)

		var valid := bool(result.get("valid", false))
		var status := str(result.get("status", ""))
		var winner_group := str(result.get("winner", ""))
		var winner_agent := _winner_agent(valid, status, winner_group, challenger_group, champion_group)
		if counts.has(winner_agent):
			counts[winner_agent] = int(counts[winner_agent]) + 1
		else:
			counts["failed"] = int(counts["failed"]) + 1
		var termination_reason := str(result.get("termination_reason", ""))
		termination_counts[termination_reason] = int(termination_counts.get(termination_reason, 0)) + 1
		var turns_played := int(result.get("turns_played", 0))
		total_turns += turns_played

		var search_metrics: Dictionary = result.get("search_metrics", {})
		var challenger_search: Dictionary = search_metrics.get(challenger_group, {})
		var champion_search: Dictionary = search_metrics.get(champion_group, {})
		challenger_elapsed_ms += float(challenger_search.get("elapsed_ms", 0.0))
		champion_elapsed_ms += float(champion_search.get("elapsed_ms", 0.0))
		challenger_simulations += int(challenger_search.get("simulations", 0))
		champion_simulations += int(champion_search.get("simulations", 0))

		var summary := {
			"pair_id": str(job.get("pair_id", "")),
			"game_id": str(job.get("game_id", "")),
			"scenario_seed": int(job.get("scenario_seed", 0)),
			"base_scenario_id": str(job.get("base_scenario_id", "")),
			"rotation_steps": int(job.get("rotation_steps", 0)),
			"variation_seed": int(job.get("variation_seed", 0)),
			"variation_passes": int(job.get("variation_passes", 1)),
			"map_profile": str(job.get("map_profile", map_profile)),
			"hex_radius": int(job.get("hex_radius", 0)),
			"challenger_group": challenger_group,
			"champion_group": champion_group,
			"max_turns": int(job.get("max_turns", 0)),
			"valid": valid,
			"status": status,
			"winner_group": winner_group,
			"winner_agent": winner_agent,
			"termination_reason": termination_reason,
			"turns_played": turns_played,
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
		print("[arena] %s family=%s radius=%d seed=%d challenger=%s result=%s/%s turns=%d search_ms=%.1f/%.1f sims=%d/%d" % [
			str(job.get("game_id", "")),
			str(job.get("base_scenario_id", "")),
			int(job.get("hex_radius", 0)),
			int(job.get("scenario_seed", 0)),
			challenger_group,
			winner_agent,
			termination_reason,
			turns_played,
			float(challenger_search.get("elapsed_ms", 0.0)),
			float(champion_search.get("elapsed_ms", 0.0)),
			int(challenger_search.get("simulations", 0)),
			int(champion_search.get("simulations", 0)),
		])

	var elapsed_ms := float(Time.get_ticks_usec() - started_usec) / 1000.0
	var decisive_games := int(counts["challenger"]) + int(counts["champion"])
	var challenger_decisive_win_rate := float(counts["challenger"]) / float(decisive_games) if decisive_games > 0 else 0.0
	var manifest := {
		"manifest_schema_version": MANIFEST_SCHEMA_VERSION,
		"decision_time_budget_ms": decision_time_budget_ms,
		"runner_type": runner_type,
		"checkpoint_sha256": FileAccess.get_sha256(str(args.get("checkpoint", PureStateNeuralEvaluator.DEFAULT_CHECKPOINT_PATH))) if challenger_evaluator == "neural" else "",
		"arena_suite_version": PureStateArenaSuite.SUITE_VERSION,
		"preset": preset,
		"seed_base": seed_base,
		"rules_version": rules_version,
		"map_profile": map_profile,
		"champion_profile": champion_profile,
		"challenger_profile": challenger_profile,
		"champion_evaluator": champion_evaluator,
		"challenger_evaluator": challenger_evaluator,
		"champion_settings": champion_settings.duplicate(true),
		"challenger_settings": challenger_settings.duplicate(true),
		"preset_games": all_jobs.size(),
		"preset_pairs": all_jobs.size() / 2,
		"shard_index": shard_index,
		"shard_count": shard_count,
		"shard_key": "pair_id_round_robin",
		"games_requested": jobs.size(),
		"pairs_requested": jobs.size() / 2,
		"counts": counts,
		"termination_counts": termination_counts,
		"decisive_games": decisive_games,
		"challenger_decisive_win_rate": challenger_decisive_win_rate,
		"mean_turns": float(total_turns) / float(game_summaries.size()) if not game_summaries.is_empty() else 0.0,
		"wall_elapsed_ms": elapsed_ms,
		"challenger_search_elapsed_ms": challenger_elapsed_ms,
		"champion_search_elapsed_ms": champion_elapsed_ms,
		"challenger_search_simulations": challenger_simulations,
		"champion_search_simulations": champion_simulations,
		"games": game_summaries,
	}

	var write_ok := _write_json(out_dir.path_join("manifest.json"), manifest)
	write_ok = _write_jsonl(out_dir.path_join("traces.jsonl"), traces) and write_ok
	print("[arena] summary map_profile=%s games=%d pairs=%d counts=%s decisive_win_rate=%.1f%% wall_ms=%.0f" % [
		map_profile,
		game_summaries.size(),
		game_summaries.size() / 2,
		str(counts),
		challenger_decisive_win_rate * 100.0,
		elapsed_ms,
	])
	PureStateNeuralEvaluator.shutdown()
	get_tree().quit(0 if write_ok and int(counts["failed"]) == 0 else 1)


func _winner_agent(
	valid: bool,
	status: String,
	winner_group: String,
	challenger_group: String,
	champion_group: String
) -> String:
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


func _write_json(path: String, value: Variant) -> bool:
	return _write_text(path, JSON.stringify(value, "  "))


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
			result[arg] = next_value
		i += 1
	return result
