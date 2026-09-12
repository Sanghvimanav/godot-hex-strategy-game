extends Node
## Generate a large, deterministic stream of full-game current-policy self-play.
##
## Starting states use the same legal seeded variation machinery as the Arena, but
## deliberately use non-benchmark seeds. Both factions use the same current neural
## checkpoint so value labels describe the current self-play policy rather than a
## mixture of handwritten and historical controllers.

const PureStateArenaSuite = preload("res://src/simulation/pure_state_arena_suite.gd")
const PureStateGameRollout = preload("res://src/simulation/pure_state_game_rollout.gd")
const PureStateTrainingData = preload("res://src/simulation/pure_state_training_data.gd")
const PureStateNeuralEvaluator = preload("res://src/simulation/pure_state_neural_evaluator.gd")
const PureStateSearchDecisionData = preload("res://src/simulation/pure_state_search_decision_data.gd")

const MANIFEST_SCHEMA_VERSION := 1
const DEFAULT_GAME_COUNT := 480
const DEFAULT_SEED_BASE := 900001
const DEFAULT_EXTRA_TURNS := 0
const SEED_STRIDE := 7919


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	var args: Dictionary = _parse_cmdline_kv()
	var profile: String = str(args.get("profile", "balanced"))
	var checkpoint: String = str(args.get("checkpoint", ""))
	var out_dir: String = str(args.get("out", "user://neural_self_play"))
	var game_count: int = int(args.get("game-count", DEFAULT_GAME_COUNT))
	var seed_base: int = int(args.get("seed-base", DEFAULT_SEED_BASE))
	var extra_turns: int = int(args.get("extra-turns", DEFAULT_EXTRA_TURNS))
	var map_profile: String = str(args.get("map-profile", PureStateArenaSuite.DEFAULT_MAP_PROFILE))
	var shard_index: int = int(args.get("shard-index", 0))
	var shard_count: int = int(args.get("shard-count", 1))
	var capture_decisions := maxi(0, int(args.get("capture-decisions-per-game", 0)))
	var opponent_evaluator := str(args.get("opponent-evaluator", "neural"))
	if opponent_evaluator not in ["neural", "handwritten"] or map_profile == PureStateArenaSuite.MAP_PROFILE_UNFAMILIAR:
		push_error("Invalid training opponent or reserved evaluation map generator")
		get_tree().quit(1)
		return

	if checkpoint.is_empty():
		push_error("--checkpoint is required")
		get_tree().quit(1)
		return
	if game_count <= 0:
		push_error("--game-count must be positive")
		get_tree().quit(1)
		return
	if extra_turns < 0:
		push_error("--extra-turns must be non-negative")
		get_tree().quit(1)
		return
	if shard_count <= 0 or shard_index < 0 or shard_index >= shard_count:
		push_error("Invalid shard %d/%d" % [shard_index, shard_count])
		get_tree().quit(1)
		return
	if map_profile not in PureStateArenaSuite.available_map_profiles():
		push_error("Unknown map profile '%s'" % map_profile)
		get_tree().quit(1)
		return

	var neural_settings: Dictionary = PureStateArenaSuite.agent_settings(profile, "neural")
	if neural_settings.is_empty():
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
	var search_decisions: Array = []
	var games: Array = []
	var requested_on_shard := 0
	var labeled_games := 0
	var unlabeled_games := 0
	var failed_games := 0
	var outcomes := {"terran": 0, "zerg": 0, "draw": 0}
	var family_counts: Dictionary = {}

	for game_index in range(shard_index, game_count, shard_count):
		requested_on_shard += 1
		var scenario_seed := seed_base + game_index * SEED_STRIDE
		if scenario_seed in PureStateArenaSuite.PHASE1_FAMILIAR_SEEDS or scenario_seed in PureStateArenaSuite.PHASE1_UNFAMILIAR_SEEDS:
			push_error("Reserved Phase 1 evaluation seed requested for training")
			get_tree().quit(1)
			return
		var state := PureStateArenaSuite.build_generated_state(
			scenario_seed,
			"full",
			map_profile
		)
		if state.is_empty():
			failed_games += 1
			continue

		var metadata_variant: Variant = state.get("arena_metadata", {})
		var metadata: Dictionary = metadata_variant as Dictionary if metadata_variant is Dictionary else {}
		var family := str(metadata.get("base_scenario_id", ""))
		var max_turns := int(PureStateArenaSuite.FAMILY_MAX_TURNS.get(family, 10)) + PureStateArenaSuite.ARENA_TURN_ALLOWANCE + extra_turns
		var game_id := "selfplay-%s-s%d" % [family, scenario_seed]

		var teacher_settings := PureStateArenaSuite.agent_settings(profile, "handwritten")
		# Family is stratified by seed residue. Alternate after each family block
		# so faction assignment is not permanently confounded with the family.
		var neural_group := "terran" if floori(float(game_index) / float(PureStateArenaSuite.SCENARIO_FAMILIES.size())) % 2 == 0 else "zerg"
		var terran_settings := teacher_settings if opponent_evaluator == "handwritten" and neural_group == "zerg" else neural_settings
		var zerg_settings := teacher_settings if opponent_evaluator == "handwritten" and neural_group == "terran" else neural_settings
		var result: Dictionary = PureStateGameRollout.play_game_with_settings(
			state.duplicate(true),
			"terran",
			"zerg",
			terran_settings,
			zerg_settings,
			max_turns,
			true
		)

		var source := {
			"base_scenario_id": family,
			"scenario_seed": scenario_seed,
			"rotation_steps": int(metadata.get("rotation_steps", 0)),
			"variation_seed": int(metadata.get("variation_seed", 0)),
			"variation_passes": int(metadata.get("variation_passes", 1)),
			"map_profile": map_profile,
			"arena_suite_version": PureStateArenaSuite.SUITE_VERSION,
			"data_policy": "current_self_play",
			"generation_seed_base": seed_base,
			"generation_game_index": game_index,
			"search_profile": profile,
			"max_turns": max_turns,
			"self_play_extra_turns": extra_turns,
			"opponent_evaluator": opponent_evaluator,
			"neural_group": neural_group,
		}
		# Capture bounded training-only alternatives even when the game remains
		# unresolved. Continuation labeling, not heuristic scores, orders siblings.
		var history: Array = result.get("history", [])
		var captured := 0
		for history_index in range(history.size() - 1, -1, -1):
			if captured >= capture_decisions:
				break
			var turn: Dictionary = history[history_index]
			if not turn.has(neural_group + "_actions"):
				continue
			var opponent_group := "zerg" if neural_group == "terran" else "terran"
			var row := PureStateSearchDecisionData.capture_decision(
				turn.get("state_before", {}), neural_group, opponent_group,
				turn[neural_group + "_actions"], 8, 4, 4, game_id,
				int(turn.get("turn", 1)), {}, source)
			if bool(row.get("valid", false)):
				search_decisions.append(row)
			captured += 1
		var built: Dictionary = PureStateTrainingData.build_examples_from_rollout(
			result,
			"terran",
			"zerg",
			game_id,
			source
		)
		var valid := bool(built.get("valid", false))
		var labeled := bool(built.get("labeled", false))
		if not valid:
			failed_games += 1
		elif labeled:
			labeled_games += 1
			family_counts[family] = int(family_counts.get(family, 0)) + 1
			for example_variant: Variant in built.get("examples", []):
				if not (example_variant is Dictionary):
					continue
				var example: Dictionary = (example_variant as Dictionary).duplicate(true)
				var example_source: Dictionary = {}
				var source_variant: Variant = example.get("source", {})
				if source_variant is Dictionary:
					example_source = (source_variant as Dictionary).duplicate(true)
				var perspective := str(example.get("perspective_group", ""))
				example_source["perspective_policy"] = "neural_current" if opponent_evaluator == "neural" or perspective == neural_group else "handwritten"
				example_source["opponent_policy"] = "neural_current" if opponent_evaluator == "neural" or perspective != neural_group else "handwritten"
				example["source"] = example_source
				examples.append(example)
			var winner := str(result.get("winner", ""))
			if winner == "terran" or winner == "zerg":
				outcomes[winner] = int(outcomes[winner]) + 1
			else:
				outcomes["draw"] = int(outcomes["draw"]) + 1
		else:
			unlabeled_games += 1

		games.append({
			"game_id": game_id,
			"game_index": game_index,
			"scenario_seed": scenario_seed,
			"base_scenario_id": family,
			"valid": bool(result.get("valid", false)),
			"labeled": labeled,
			"status": str(result.get("status", "")),
			"winner": str(result.get("winner", "")),
			"turns_played": int(result.get("turns_played", 0)),
			"example_count": int(built.get("example_count", 0)),
			"max_turns": max_turns,
		})

	var manifest := {
		"manifest_schema_version": MANIFEST_SCHEMA_VERSION,
		"generator": "current_policy_full_game_self_play",
		"profile": profile,
		"map_profile": map_profile,
		"seed_base": seed_base,
		"seed_stride": SEED_STRIDE,
		"extra_turns": extra_turns,
		"game_count_total": game_count,
		"shard_index": shard_index,
		"shard_count": shard_count,
		"games_requested": requested_on_shard,
		"games_labeled": labeled_games,
		"games_unlabeled": unlabeled_games,
		"games_failed": failed_games,
		"example_count": examples.size(),
		"outcomes": outcomes,
		"family_counts": family_counts,
		"data_policy": "current_self_play",
	}

	var ok := _write_text(abs_out.path_join("examples.jsonl"), _to_jsonl(examples))
	if capture_decisions > 0:
		ok = _write_text(abs_out.path_join("search_decisions.jsonl"), _to_jsonl(search_decisions)) and ok
		ok = _write_text(abs_out.path_join("rejected_continuations.jsonl"), "") and ok
	ok = _write_text(abs_out.path_join("games.jsonl"), _to_jsonl(games)) and ok
	ok = _write_text(abs_out.path_join("manifest.json"), JSON.stringify(manifest, "  ") + "\n") and ok
	print("[self-play] shard=%d/%d requested=%d labeled=%d unresolved=%d failed=%d examples=%d extra_turns=%d" % [
		shard_index,
		shard_count,
		requested_on_shard,
		labeled_games,
		unlabeled_games,
		failed_games,
		examples.size(),
		extra_turns,
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
	var i := 0
	while i < raw.size():
		var arg := str(raw[i]).strip_edges()
		if arg.begins_with("--"):
			arg = arg.substr(2)
		if arg.contains("="):
			var parts: PackedStringArray = arg.split("=", true, 1)
			result[parts[0]] = parts[1]
		elif not arg.is_empty():
			var next_value := ""
			if i + 1 < raw.size() and not str(raw[i + 1]).begins_with("-"):
				next_value = str(raw[i + 1]).strip_edges()
				i += 1
			result[arg] = next_value if not next_value.is_empty() else "true"
		i += 1
	return result
