extends Node
## Headless batch self-play dataset generator for the neural value model.
##
## Run directly:
## godot --headless --path . res://tools/self_play_dataset.tscn -- \
##   --preset=starter --out=user://self_play_dataset --rules-version=<git-sha>
##
## Prefer tools/run_self_play_dataset.sh, which injects the current git SHA.

const PureStateTrainingData = preload("res://src/simulation/pure_state_training_data.gd")
const PureStateSelfPlaySuite = preload("res://src/simulation/pure_state_self_play_suite.gd")

const DATASET_MANIFEST_SCHEMA_VERSION := 1


func _ready() -> void:
	call_deferred("_run_dataset")


func _run_dataset() -> void:
	var args := _parse_cmdline_kv()
	var preset := str(args.get("preset", "starter"))
	var out_dir := str(args.get("out", "user://self_play_dataset"))
	var rules_version := str(args.get("rules-version", "unknown"))
	var max_games := int(args.get("max-games", "0"))

	var jobs: Array = PureStateSelfPlaySuite.get_preset(preset)
	if jobs.is_empty():
		push_error("Unknown or empty self-play preset '%s'. Available: %s" % [
			preset,
			str(PureStateSelfPlaySuite.available_presets()),
		])
		get_tree().quit(1)
		return
	if max_games > 0 and max_games < jobs.size():
		jobs = jobs.slice(0, max_games)

	var abs_out := ProjectSettings.globalize_path(out_dir)
	if DirAccess.make_dir_recursive_absolute(abs_out) != OK:
		push_error("Unable to create dataset output directory: %s" % abs_out)
		get_tree().quit(1)
		return
	if rules_version == "unknown" or rules_version.is_empty():
		push_warning("Self-play dataset has no rules git SHA; pass --rules-version or use run_self_play_dataset.sh")

	var all_examples: Array = []
	var all_traces: Array = []
	var game_summaries: Array = []
	var labeled_games := 0
	var unlabeled_games := 0
	var failed_games := 0
	var outcomes := {"terran": 0, "zerg": 0, "draw": 0}

	for job_variant in jobs:
		if not (job_variant is Dictionary):
			failed_games += 1
			continue
		var job: Dictionary = job_variant
		var game_id := str(job.get("game_id", ""))
		var source_metadata := {
			"rules_version": rules_version,
			"self_play_suite_version": PureStateSelfPlaySuite.SUITE_VERSION,
			"dataset_preset": preset,
			"budget_profile": str(job.get("budget_profile", "")),
			"rotation_steps": int(job.get("rotation_steps", 0)),
			"variation_seed": int(job.get("variation_seed", 0)),
			"base_scenario_id": str(job.get("scenario_id", "")),
		}
		var result := PureStateTrainingData.generate_game_examples(
			job.get("state", {}) as Dictionary,
			str(job.get("group_a", "terran")),
			str(job.get("group_b", "zerg")),
			game_id,
			int(job.get("max_turns", 1)),
			int(job.get("max_actions_per_unit", 1)),
			int(job.get("own_max_plans", 1)),
			int(job.get("opponent_max_plans", 1)),
			source_metadata
		)

		var valid := bool(result.get("valid", false))
		var labeled := bool(result.get("labeled", false))
		var status := str(result.get("status", ""))
		var winner := str(result.get("winner", ""))
		var example_count := int(result.get("example_count", 0))
		var trace = result.get("trace", null)
		if trace is Dictionary:
			all_traces.append((trace as Dictionary).duplicate(true))
		if not valid:
			failed_games += 1
		elif labeled:
			labeled_games += 1
			all_examples.append_array((result.get("examples", []) as Array).duplicate(true))
			if winner.is_empty():
				outcomes["draw"] = int(outcomes["draw"]) + 1
			elif outcomes.has(winner):
				outcomes[winner] = int(outcomes[winner]) + 1
		else:
			unlabeled_games += 1

		var summary := {
			"game_id": game_id,
			"scenario_id": str(job.get("scenario_id", "")),
			"budget_profile": str(job.get("budget_profile", "")),
			"rotation_steps": int(job.get("rotation_steps", 0)),
			"variation_seed": int(job.get("variation_seed", 0)),
			"max_turns": int(job.get("max_turns", 0)),
			"own_max_plans": int(job.get("own_max_plans", 0)),
			"opponent_max_plans": int(job.get("opponent_max_plans", 0)),
			"valid": valid,
			"labeled": labeled,
			"status": status,
			"winner": winner,
			"turns_played": int(result.get("turns_played", 0)),
			"example_count": example_count,
		}
		game_summaries.append(summary)
		print("[self-play] %s profile=%s rotation=%d seed=%d status=%s winner=%s turns=%d examples=%d" % [
			game_id,
			str(job.get("budget_profile", "")),
			int(job.get("rotation_steps", 0)),
			int(job.get("variation_seed", 0)),
			status,
			winner,
			int(result.get("turns_played", 0)),
			example_count,
		])

	var manifest := {
		"manifest_schema_version": DATASET_MANIFEST_SCHEMA_VERSION,
		"training_example_schema_version": PureStateTrainingData.SCHEMA_VERSION,
		"trace_schema_version": PureStateTrainingData.TRACE_SCHEMA_VERSION,
		"self_play_suite_version": PureStateSelfPlaySuite.SUITE_VERSION,
		"preset": preset,
		"rules_version": rules_version,
		"budget_profiles": PureStateSelfPlaySuite.BUDGET_PROFILES.duplicate(true),
		"games_requested": jobs.size(),
		"games_labeled": labeled_games,
		"games_unlabeled": unlabeled_games,
		"games_failed": failed_games,
		"example_count": all_examples.size(),
		"trace_count": all_traces.size(),
		"trace_file": "traces.jsonl",
		"outcomes": outcomes,
		"games": game_summaries,
	}

	var examples_path := out_dir.path_join("examples.jsonl")
	var traces_path := out_dir.path_join("traces.jsonl")
	var manifest_path := out_dir.path_join("manifest.json")
	var write_ok := _write_text(examples_path, PureStateTrainingData.to_jsonl(all_examples))
	write_ok = _write_text(traces_path, PureStateTrainingData.to_jsonl(all_traces)) and write_ok
	write_ok = _write_json(manifest_path, manifest) and write_ok
	print("[self-play] wrote %s" % ProjectSettings.globalize_path(examples_path))
	print("[self-play] wrote %s" % ProjectSettings.globalize_path(traces_path))
	print("[self-play] wrote %s" % ProjectSettings.globalize_path(manifest_path))
	print("[self-play] summary games=%d labeled=%d unlabeled=%d failed=%d examples=%d outcomes=%s" % [
		jobs.size(),
		labeled_games,
		unlabeled_games,
		failed_games,
		all_examples.size(),
		str(outcomes),
	])
	if failed_games > 0:
		push_warning("Self-play batch completed with %d failed game(s); see manifest for per-game status" % failed_games)

	# Individual search/simulation failures are recorded as unusable games in the
	# manifest. Dataset-quality policy belongs to the caller so exploratory batches
	# can still train from the valid terminal games that were successfully produced.
	get_tree().quit(0 if write_ok else 1)


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


func _write_text(path: String, text: String) -> bool:
	var abs_path := ProjectSettings.globalize_path(path)
	var file := FileAccess.open(abs_path, FileAccess.WRITE)
	if file == null:
		push_error("Cannot write %s" % abs_path)
		return false
	file.store_string(text)
	file.close()
	return true


func _write_json(path: String, data: Dictionary) -> bool:
	return _write_text(path, JSON.stringify(data, "  ") + "\n")
