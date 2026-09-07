extends Node
## Collect value targets from states the neural policy actually visits against the
## handwritten champion. This is a DAgger-style state-distribution correction:
## the current neural model creates the trajectory, then the terminal game result
## labels every visited state from both perspectives.

const PureStateArenaSuite = preload("res://src/simulation/pure_state_arena_suite.gd")
const PureStateGameRollout = preload("res://src/simulation/pure_state_game_rollout.gd")
const PureStateTrainingData = preload("res://src/simulation/pure_state_training_data.gd")
const PureStateNeuralEvaluator = preload("res://src/simulation/pure_state_neural_evaluator.gd")
const DeterministicShard = preload("res://tools/deterministic_shard.gd")

const MANIFEST_SCHEMA_VERSION := 1


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	var args: Dictionary = _parse_cmdline_kv()
	var preset: String = str(args.get("preset", "fast"))
	var profile: String = str(args.get("profile", "balanced"))
	var checkpoint: String = str(args.get("checkpoint", ""))
	var out_dir: String = str(args.get("out", "user://neural_policy_dataset"))
	var shard_index: int = int(args.get("shard-index", 0))
	var shard_count: int = int(args.get("shard-count", 1))
	var seed_base: int = int(args.get("seed-base", PureStateArenaSuite.DEFAULT_SEED_BASE))
	if checkpoint.is_empty():
		push_error("--checkpoint is required")
		get_tree().quit(1)
		return
	if shard_count <= 0 or shard_index < 0 or shard_index >= shard_count:
		push_error("Invalid shard %d/%d" % [shard_index, shard_count])
		get_tree().quit(1)
		return

	var jobs: Array = PureStateArenaSuite.get_preset(preset, seed_base)
	if jobs.is_empty():
		push_error("Unknown or empty arena preset '%s'" % preset)
		get_tree().quit(1)
		return
	jobs = DeterministicShard.filter_grouped_jobs_round_robin(
		jobs,
		"pair_id",
		shard_index,
		shard_count
	)

	var handwritten_settings: Dictionary = PureStateArenaSuite.agent_settings(profile, "handwritten")
	var neural_settings: Dictionary = PureStateArenaSuite.agent_settings(profile, "neural")
	if handwritten_settings.is_empty() or neural_settings.is_empty():
		push_error("Unknown Arena profile '%s'" % profile)
		get_tree().quit(1)
		return
	var evaluator_settings: Dictionary = {}
	var evaluator_variant: Variant = neural_settings.get("evaluator_settings", {})
	if evaluator_variant is Dictionary:
		evaluator_settings = (evaluator_variant as Dictionary).duplicate(true)
	evaluator_settings["checkpoint_path"] = checkpoint
	neural_settings["evaluator_settings"] = evaluator_settings

	var abs_out: String = ProjectSettings.globalize_path(out_dir)
	if DirAccess.make_dir_recursive_absolute(abs_out) != OK:
		push_error("Unable to create %s" % abs_out)
		get_tree().quit(1)
		return

	var examples: Array = []
	var traces: Array = []
	var games: Array = []
	var labeled_games: int = 0
	var unlabeled_games: int = 0
	var failed_games: int = 0
	var outcomes := {"neural": 0, "handwritten": 0, "draw": 0}

	for job_variant: Variant in jobs:
		if not (job_variant is Dictionary):
			failed_games += 1
			continue
		var job: Dictionary = job_variant as Dictionary
		var neural_group: String = str(job.get("challenger_group", ""))
		var handwritten_group: String = str(job.get("champion_group", ""))
		var terran_settings: Dictionary = neural_settings if neural_group == "terran" else handwritten_settings
		var zerg_settings: Dictionary = neural_settings if neural_group == "zerg" else handwritten_settings
		var result: Dictionary = PureStateGameRollout.play_game_with_settings(
			(job.get("state", {}) as Dictionary).duplicate(true),
			"terran",
			"zerg",
			terran_settings,
			zerg_settings,
			int(job.get("max_turns", 10)),
			true
		)

		var source := {
			"base_scenario_id": str(job.get("base_scenario_id", "")),
			"scenario_seed": int(job.get("scenario_seed", 0)),
			"rotation_steps": int(job.get("rotation_steps", 0)),
			"variation_seed": int(job.get("variation_seed", 0)),
			"variation_passes": int(job.get("variation_passes", 1)),
			"arena_suite_version": PureStateArenaSuite.SUITE_VERSION,
			"arena_preset": preset,
			"arena_profile": profile,
			"data_policy": "neural_vs_handwritten",
			"neural_group": neural_group,
			"handwritten_group": handwritten_group,
			"max_turns": int(job.get("max_turns", 10)),
		}
		var built: Dictionary = PureStateTrainingData.build_examples_from_rollout(
			result,
			"terran",
			"zerg",
			str(job.get("game_id", "")),
			source
		)
		var valid: bool = bool(built.get("valid", false))
		var labeled: bool = bool(built.get("labeled", false))
		if not valid:
			failed_games += 1
		elif labeled:
			labeled_games += 1
			for example_variant: Variant in built.get("examples", []):
				if not (example_variant is Dictionary):
					continue
				var example: Dictionary = (example_variant as Dictionary).duplicate(true)
				var example_source: Dictionary = {}
				var source_variant: Variant = example.get("source", {})
				if source_variant is Dictionary:
					example_source = (source_variant as Dictionary).duplicate(true)
				var perspective_group: String = str(example.get("perspective_group", ""))
				example_source["perspective_policy"] = "neural" if perspective_group == neural_group else "handwritten"
				example_source["opponent_policy"] = "handwritten" if perspective_group == neural_group else "neural"
				example["source"] = example_source
				examples.append(example)
			var winner: String = str(result.get("winner", ""))
			if winner.is_empty():
				outcomes["draw"] = int(outcomes["draw"]) + 1
			elif winner == neural_group:
				outcomes["neural"] = int(outcomes["neural"]) + 1
			elif winner == handwritten_group:
				outcomes["handwritten"] = int(outcomes["handwritten"]) + 1
		else:
			unlabeled_games += 1

		traces.append({
			"game_id": str(job.get("game_id", "")),
			"pair_id": str(job.get("pair_id", "")),
			"neural_group": neural_group,
			"winner": str(result.get("winner", "")),
			"status": str(result.get("status", "")),
			"history": (result.get("history", []) as Array).duplicate(true),
		})
		games.append({
			"game_id": str(job.get("game_id", "")),
			"pair_id": str(job.get("pair_id", "")),
			"base_scenario_id": str(job.get("base_scenario_id", "")),
			"neural_group": neural_group,
			"valid": bool(result.get("valid", false)),
			"status": str(result.get("status", "")),
			"winner": str(result.get("winner", "")),
			"turns_played": int(result.get("turns_played", 0)),
			"example_count": int(built.get("example_count", 0)),
		})

	var manifest := {
		"manifest_schema_version": MANIFEST_SCHEMA_VERSION,
		"preset": preset,
		"profile": profile,
		"seed_base": seed_base,
		"shard_index": shard_index,
		"shard_count": shard_count,
		"games_requested": jobs.size(),
		"games_labeled": labeled_games,
		"games_unlabeled": unlabeled_games,
		"games_failed": failed_games,
		"example_count": examples.size(),
		"outcomes": outcomes,
		"data_policy": "neural_vs_handwritten",
		"games": games,
	}
	var ok: bool = _write_text(abs_out.path_join("examples.jsonl"), _to_jsonl(examples))
	ok = _write_text(abs_out.path_join("traces.jsonl"), _to_jsonl(traces)) and ok
	ok = _write_text(abs_out.path_join("manifest.json"), JSON.stringify(manifest, "  ") + "\n") and ok
	print("[neural-policy] shard=%d/%d games=%d labeled=%d unlabeled=%d failed=%d examples=%d outcomes=%s" % [
		shard_index,
		shard_count,
		jobs.size(),
		labeled_games,
		unlabeled_games,
		failed_games,
		examples.size(),
		str(outcomes),
	])
	PureStateNeuralEvaluator.shutdown()
	get_tree().quit(0 if ok and failed_games == 0 else 1)


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
