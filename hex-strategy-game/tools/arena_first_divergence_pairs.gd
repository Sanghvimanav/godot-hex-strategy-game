extends Node
## Mine policy-aligned hard negatives from decisive Arena losses.
##
## Games can be sharded across independent workers. Within each selected loss,
## test only a small bounded number of neural/handwritten divergences. The
## recorded Arena result supplies the neural branch loss, so each tested
## divergence needs only one full continuation for the handwritten alternative.

const LegacyMiner = preload("res://tools/arena_divergence_pairs.gd")
const GameplayAI = preload("res://src/battle/ai/gameplay_ai.gd")
const PureStateArenaSuite = preload("res://src/simulation/pure_state_arena_suite.gd")
const PureStateCommandHexRules = preload("res://src/simulation/pure_state_command_hex_rules.gd")
const PureStateNeuralEvaluator = preload("res://src/simulation/pure_state_neural_evaluator.gd")
const PolicyContinuation = preload("res://tools/policy_continuation.gd")

const PAIR_SCHEMA_VERSION := 2
const MANIFEST_SCHEMA_VERSION := 1
const DEFAULT_MAX_PAIRS := 16
const DEFAULT_MAX_DIVERGENCES_PER_GAME := 3


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	var legacy = LegacyMiner.new()
	var args: Dictionary = legacy._parse_cmdline_kv()
	var arena_root: String = ProjectSettings.globalize_path(str(args.get("arena-root", "")))
	var out_dir: String = ProjectSettings.globalize_path(str(args.get("out", "user://arena_hard_negatives")))
	var checkpoint: String = str(args.get("neural-checkpoint", ""))
	var profile: String = str(args.get("profile", "balanced"))
	var max_pairs: int = maxi(1, int(args.get("max-pairs", DEFAULT_MAX_PAIRS)))
	var max_divergences_per_game: int = maxi(
		1,
		int(args.get("max-divergences-per-game", DEFAULT_MAX_DIVERGENCES_PER_GAME))
	)
	var shard_index: int = int(args.get("shard-index", 0))
	var shard_count: int = maxi(1, int(args.get("shard-count", 1)))
	if arena_root.is_empty() or checkpoint.is_empty():
		push_error("--arena-root and --neural-checkpoint are required")
		get_tree().quit(1)
		return
	if shard_index < 0 or shard_index >= shard_count:
		push_error("--shard-index must be in [0, --shard-count)")
		get_tree().quit(1)
		return
	if DirAccess.make_dir_recursive_absolute(out_dir) != OK:
		push_error("Unable to create %s" % out_dir)
		get_tree().quit(1)
		return

	var manifest_paths: Array[String] = []
	var trace_paths: Array[String] = []
	legacy._find_named_files(arena_root, "manifest.json", manifest_paths)
	legacy._find_named_files(arena_root, "traces.jsonl", trace_paths)
	if manifest_paths.is_empty() or trace_paths.is_empty():
		push_error("Arena shard artifacts are missing manifest.json or traces.jsonl")
		get_tree().quit(1)
		return

	var preset: String = ""
	var seed_base: int = PureStateArenaSuite.DEFAULT_SEED_BASE
	var trace_by_game: Dictionary = {}
	for trace_path: String in trace_paths:
		var rows_variant: Variant = legacy._read_jsonl(trace_path)
		if rows_variant == null:
			get_tree().quit(1)
			return
		for row_variant: Variant in rows_variant as Array:
			if row_variant is Dictionary:
				trace_by_game[str((row_variant as Dictionary).get("game_id", ""))] = row_variant

	var game_summary_by_id: Dictionary = {}
	for manifest_path: String in manifest_paths:
		var manifest_variant: Variant = legacy._read_json(manifest_path)
		if not (manifest_variant is Dictionary):
			continue
		var manifest: Dictionary = manifest_variant as Dictionary
		if preset.is_empty():
			preset = str(manifest.get("preset", "fast"))
			seed_base = int(manifest.get("seed_base", PureStateArenaSuite.DEFAULT_SEED_BASE))
		for game_variant: Variant in manifest.get("games", []):
			if game_variant is Dictionary:
				var game: Dictionary = game_variant as Dictionary
				game_summary_by_id[str(game.get("game_id", ""))] = game

	if preset.is_empty():
		preset = "fast"
	var jobs: Array = PureStateArenaSuite.get_preset(preset, seed_base)
	var job_by_id: Dictionary = {}
	for job_variant: Variant in jobs:
		if job_variant is Dictionary:
			var job: Dictionary = job_variant as Dictionary
			job_by_id[str(job.get("game_id", ""))] = job

	var handwritten_settings: Dictionary = PureStateArenaSuite.agent_settings(
		profile,
		GameplayAI.EVALUATOR_HANDWRITTEN
	)
	var neural_settings: Dictionary = PureStateArenaSuite.agent_settings(
		profile,
		GameplayAI.EVALUATOR_NEURAL
	)
	if handwritten_settings.is_empty() or neural_settings.is_empty():
		push_error("Unknown Arena profile '%s'" % profile)
		get_tree().quit(1)
		return
	var budget := {
		"max_actions_per_unit": int(neural_settings.get("own_max_actions_per_unit", 8)),
		"own_max_plans": int(neural_settings.get("own_max_plans", 4)),
		"opponent_max_plans": int(neural_settings.get("opponent_max_plans", 4)),
	}

	var helper = PolicyContinuation.new()
	var pairs: Array = []
	var diagnostics: Array = []
	var games_considered: int = 0
	var divergences_considered: int = 0
	var branch_unlabeled: int = 0
	var no_preference: int = 0
	var invalid: int = 0
	var decisive_losses_seen: int = 0

	var game_ids: Array = trace_by_game.keys()
	game_ids.sort()
	for game_id_variant: Variant in game_ids:
		if pairs.size() >= max_pairs:
			break
		var game_id: String = str(game_id_variant)
		if not job_by_id.has(game_id) or not game_summary_by_id.has(game_id):
			invalid += 1
			continue
		var summary: Dictionary = game_summary_by_id[game_id] as Dictionary
		if str(summary.get("winner_agent", "")) != "champion":
			continue

		var loss_index: int = decisive_losses_seen
		decisive_losses_seen += 1
		if loss_index % shard_count != shard_index:
			continue

		var trace: Dictionary = trace_by_game[game_id] as Dictionary
		var job: Dictionary = job_by_id[game_id] as Dictionary
		var neural_group: String = str(job.get("challenger_group", ""))
		var opponent_group: String = str(job.get("champion_group", ""))
		var state: Dictionary = (job.get("state", {}) as Dictionary).duplicate(true)
		var command_hexes: Dictionary = PureStateCommandHexRules.ensure_command_hexes(
			state,
			"terran",
			"zerg"
		)
		state["command_hexes"] = command_hexes.duplicate(true)
		var max_turns: int = int(job.get("max_turns", 10))
		var history: Array = trace.get("history", []) as Array
		var divergences_in_game: int = 0
		var pair_found: bool = false
		games_considered += 1

		for turn_offset: int in range(history.size()):
			var turn_variant: Variant = history[turn_offset]
			if not (turn_variant is Dictionary):
				invalid += 1
				break
			var turn: Dictionary = turn_variant as Dictionary
			var recorded_state_variant: Variant = turn.get("state_before", {})
			if recorded_state_variant is Dictionary and not (recorded_state_variant as Dictionary).is_empty():
				state = (recorded_state_variant as Dictionary).duplicate(true)
				state["command_hexes"] = command_hexes.duplicate(true)

			var neural_actions_variant: Variant = turn.get(neural_group + "_actions", [])
			var opponent_actions_variant: Variant = turn.get(opponent_group + "_actions", [])
			if not (neural_actions_variant is Array) or not (opponent_actions_variant is Array):
				invalid += 1
				break
			var neural_actions: Array = (neural_actions_variant as Array).duplicate(true)
			var opponent_actions: Array = (opponent_actions_variant as Array).duplicate(true)

			var handwritten_decision: Dictionary = GameplayAI.choose_actions(
				state,
				neural_group,
				opponent_group,
				handwritten_settings
			)
			if not bool(handwritten_decision.get("valid", false)):
				invalid += 1
				break
			var handwritten_actions: Array = (
				handwritten_decision.get("actions", []) as Array
			).duplicate(true)

			if JSON.stringify(neural_actions) != JSON.stringify(handwritten_actions):
				if divergences_in_game >= max_divergences_per_game:
					break
				divergences_in_game += 1
				divergences_considered += 1

				var neural_leaf_variant: Variant = legacy._simulate_branch(
					state,
					neural_group,
					neural_actions,
					opponent_group,
					opponent_actions,
					command_hexes
				)
				var handwritten_leaf_variant: Variant = legacy._simulate_branch(
					state,
					neural_group,
					handwritten_actions,
					opponent_group,
					opponent_actions,
					command_hexes
				)
				if not (neural_leaf_variant is Dictionary) or not (handwritten_leaf_variant is Dictionary):
					invalid += 1
					break

				var remaining_turns: int = maxi(0, max_turns - (turn_offset + 1))
				print(
					"[arena-hard-negatives] shard=%d/%d game=%s divergence=%d turn=%d remaining_turns=%d"
					% [
						shard_index,
						shard_count,
						game_id,
						divergences_in_game,
						turn_offset,
						remaining_turns,
					]
				)
				var handwritten_result: Dictionary = helper.continue_from_leaf(
					state,
					handwritten_leaf_variant as Dictionary,
					neural_group,
					opponent_group,
					remaining_turns,
					budget,
					"",
					PolicyContinuation.POLICY_NEURAL_VS_HANDWRITTEN,
					checkpoint
				)
				if not bool(handwritten_result.get("valid", false)):
					invalid += 1
					break
				if not bool(handwritten_result.get("labeled", false)):
					branch_unlabeled += 1
				else:
					var handwritten_outcome: float = float(
						handwritten_result.get("perspective_outcome", 0.0)
					)
					if handwritten_outcome <= -1.0:
						no_preference += 1
					else:
						var source := {
							"base_scenario_id": str(job.get("base_scenario_id", "")),
							"scenario_seed": int(job.get("scenario_seed", 0)),
							"arena_pair_id": str(job.get("pair_id", "")),
							"arena_game_id": game_id,
							"arena_winner_agent": "champion",
							"data_origin": "arena_divergence_hard_negative",
							"continuation_policy": PolicyContinuation.POLICY_NEURAL_VS_HANDWRITTEN,
							"neural_outcome_source": "recorded_arena_loss",
						}
						pairs.append({
							"schema_version": PAIR_SCHEMA_VERSION,
							"game_id": game_id,
							"turn_index": turn_offset,
							"perspective_group": neural_group,
							"opponent_group": opponent_group,
							"response_index": -1,
							"pair_kind": "outcome",
							"weight": 1.0,
							"better_candidate_index": -1,
							"worse_candidate_index": -1,
							"better_state": (
								handwritten_result.get("state_after_first_turn", {}) as Dictionary
							).duplicate(true),
							"worse_state": (neural_leaf_variant as Dictionary).duplicate(true),
							"better_outcome": handwritten_outcome,
							"worse_outcome": -1.0,
							"better_turns_after_branch": int(
								handwritten_result.get("turns_played_after_branch", 0)
							),
							"worse_turns_after_branch": maxi(
								0,
								int(summary.get("turns_played", 0)) - (turn_offset + 1)
							),
							"better_leaf_terminal": bool(
								handwritten_result.get("leaf_terminal", false)
							),
							"worse_leaf_terminal": (
								turn_offset + 1 >= int(summary.get("turns_played", 0))
							),
							"continuation_policy": PolicyContinuation.POLICY_NEURAL_VS_HANDWRITTEN,
							"priority_reasons": [
								"arena_bounded_divergence",
								"recorded_neural_loss",
								"handwritten_alternative_better",
							],
							"source": source,
						})
						diagnostics.append({
							"game_id": game_id,
							"turn_index": turn_offset,
							"divergence_index": divergences_in_game,
							"neural_group": neural_group,
							"neural_actions": neural_actions,
							"handwritten_actions": handwritten_actions,
							"opponent_actions": opponent_actions,
							"neural_outcome": -1.0,
							"handwritten_outcome": handwritten_outcome,
							"pair_kind": "outcome",
						})
						pair_found = true

				if pair_found or divergences_in_game >= max_divergences_per_game:
					break

			var actual_next_variant: Variant = legacy._simulate_branch(
				state,
				neural_group,
				neural_actions,
				opponent_group,
				opponent_actions,
				command_hexes
			)
			if not (actual_next_variant is Dictionary):
				invalid += 1
				break
			state = (actual_next_variant as Dictionary).duplicate(true)

	var manifest := {
		"manifest_schema_version": MANIFEST_SCHEMA_VERSION,
		"pair_schema_version": PAIR_SCHEMA_VERSION,
		"arena_preset": preset,
		"arena_profile": profile,
		"shard_index": shard_index,
		"shard_count": shard_count,
		"games_considered": games_considered,
		"decisive_losses_seen": decisive_losses_seen,
		"divergences_considered": divergences_considered,
		"pairs_written": pairs.size(),
		"branch_unlabeled": branch_unlabeled,
		"no_preference": no_preference,
		"neural_better": 0,
		"invalid": invalid,
		"continuation_policy": PolicyContinuation.POLICY_NEURAL_VS_HANDWRITTEN,
		"same_actual_opponent_action": true,
		"bounded_divergences_per_game": max_divergences_per_game,
		"recorded_neural_loss_reused": true,
		"max_full_continuations_per_game": max_divergences_per_game,
	}
	var ok: bool = legacy._write_text(
		out_dir.path_join("arena_hard_negative_pairs.jsonl"),
		legacy._to_jsonl(pairs)
	)
	ok = legacy._write_text(
		out_dir.path_join("arena_divergences.jsonl"),
		legacy._to_jsonl(diagnostics)
	) and ok
	ok = legacy._write_text(
		out_dir.path_join("arena_hard_negative_manifest.json"),
		JSON.stringify(manifest, "  ") + "\n"
	) and ok
	print(
		"[arena-hard-negatives] shard=%d/%d games=%d divergences=%d pairs=%d unlabeled=%d no_preference=%d invalid=%d"
		% [
			shard_index,
			shard_count,
			games_considered,
			divergences_considered,
			pairs.size(),
			branch_unlabeled,
			no_preference,
			invalid,
		]
	)
	PureStateNeuralEvaluator.shutdown()
	get_tree().quit(0 if ok and invalid == 0 else 1)
