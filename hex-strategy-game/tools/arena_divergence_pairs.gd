extends Node
## Mine direct hard negatives from Arena losses.
##
## For each game, reconstruct the Arena state turn by turn. When the current neural
## policy and handwritten champion first disagree for the neural-controlled side,
## hold the opponent's simultaneous action fixed, simulate both alternatives, and
## continue both branches with neural-vs-handwritten play. If the handwritten
## alternative produces a strictly better terminal result, emit a ranking pair.

const GameplayAI = preload("res://src/battle/ai/gameplay_ai.gd")
const PureStateArenaSuite = preload("res://src/simulation/pure_state_arena_suite.gd")
const PureStateGameRollout = preload("res://src/simulation/pure_state_game_rollout.gd")
const PureStateSimulator = preload("res://src/simulation/pure_state_simulator.gd")
const PureStateCommandHexRules = preload("res://src/simulation/pure_state_command_hex_rules.gd")
const PureStateNeuralEvaluator = preload("res://src/simulation/pure_state_neural_evaluator.gd")
const PolicyContinuation = preload("res://tools/policy_continuation.gd")

const PAIR_SCHEMA_VERSION := 2
const MANIFEST_SCHEMA_VERSION := 1
const DEFAULT_MAX_PAIRS := 16


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	var args: Dictionary = _parse_cmdline_kv()
	var arena_root: String = ProjectSettings.globalize_path(str(args.get("arena-root", "")))
	var out_dir: String = ProjectSettings.globalize_path(str(args.get("out", "user://arena_hard_negatives")))
	var checkpoint: String = str(args.get("neural-checkpoint", ""))
	var profile: String = str(args.get("profile", "balanced"))
	var max_pairs: int = maxi(1, int(args.get("max-pairs", DEFAULT_MAX_PAIRS)))
	if arena_root.is_empty() or checkpoint.is_empty():
		push_error("--arena-root and --neural-checkpoint are required")
		get_tree().quit(1)
		return
	if DirAccess.make_dir_recursive_absolute(out_dir) != OK:
		push_error("Unable to create %s" % out_dir)
		get_tree().quit(1)
		return

	var manifest_paths: Array[String] = []
	var trace_paths: Array[String] = []
	_find_named_files(arena_root, "manifest.json", manifest_paths)
	_find_named_files(arena_root, "traces.jsonl", trace_paths)
	if manifest_paths.is_empty() or trace_paths.is_empty():
		push_error("Arena shard artifacts are missing manifest.json or traces.jsonl")
		get_tree().quit(1)
		return

	var preset: String = ""
	var seed_base: int = PureStateArenaSuite.DEFAULT_SEED_BASE
	var trace_by_game: Dictionary = {}
	for trace_path: String in trace_paths:
		var rows_variant: Variant = _read_jsonl(trace_path)
		if rows_variant == null:
			get_tree().quit(1)
			return
		for row_variant: Variant in rows_variant as Array:
			if row_variant is Dictionary:
				trace_by_game[str((row_variant as Dictionary).get("game_id", ""))] = row_variant

	var game_summary_by_id: Dictionary = {}
	for manifest_path: String in manifest_paths:
		var manifest_variant: Variant = _read_json(manifest_path)
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

	var handwritten_settings: Dictionary = PureStateArenaSuite.agent_settings(profile, GameplayAI.EVALUATOR_HANDWRITTEN)
	var neural_settings: Dictionary = PureStateArenaSuite.agent_settings(profile, GameplayAI.EVALUATOR_NEURAL)
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
	var neural_better: int = 0
	var invalid: int = 0

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
		if str(summary.get("winner_agent", "")) == "challenger":
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
		games_considered += 1
		var emitted_for_game: bool = false

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
			var handwritten_actions: Array = (handwritten_decision.get("actions", []) as Array).duplicate(true)

			if JSON.stringify(neural_actions) != JSON.stringify(handwritten_actions):
				divergences_considered += 1
				var neural_leaf_variant: Variant = _simulate_branch(
					state,
					neural_group,
					neural_actions,
					opponent_group,
					opponent_actions,
					command_hexes
				)
				var handwritten_leaf_variant: Variant = _simulate_branch(
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
				var neural_result: Dictionary = helper.continue_from_leaf(
					state,
					neural_leaf_variant as Dictionary,
					neural_group,
					opponent_group,
					remaining_turns,
					budget,
					"",
					PolicyContinuation.POLICY_NEURAL_VS_HANDWRITTEN,
					checkpoint
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
				if not bool(neural_result.get("valid", false)) or not bool(handwritten_result.get("valid", false)):
					invalid += 1
					break
				if not bool(neural_result.get("labeled", false)) or not bool(handwritten_result.get("labeled", false)):
					branch_unlabeled += 1
				else:
					var comparison: Dictionary = helper.compare_terminal_results(
						handwritten_result,
						neural_result
					)
					if not bool(comparison.get("preferred", false)):
						no_preference += 1
					elif not bool(comparison.get("left_better", false)):
						neural_better += 1
					else:
						var source := {
							"base_scenario_id": str(job.get("base_scenario_id", "")),
							"scenario_seed": int(job.get("scenario_seed", 0)),
							"arena_pair_id": str(job.get("pair_id", "")),
							"arena_game_id": game_id,
							"arena_winner_agent": str(summary.get("winner_agent", "")),
							"data_origin": "arena_divergence_hard_negative",
							"continuation_policy": PolicyContinuation.POLICY_NEURAL_VS_HANDWRITTEN,
						}
						pairs.append({
							"schema_version": PAIR_SCHEMA_VERSION,
							"game_id": game_id,
							"turn_index": turn_offset,
							"perspective_group": neural_group,
							"opponent_group": opponent_group,
							"response_index": -1,
							"pair_kind": str(comparison.get("pair_kind", "")),
							"weight": float(comparison.get("weight", 1.0)),
							"better_candidate_index": -1,
							"worse_candidate_index": -1,
							"better_state": (handwritten_result.get("state_after_first_turn", {}) as Dictionary).duplicate(true),
							"worse_state": (neural_result.get("state_after_first_turn", {}) as Dictionary).duplicate(true),
							"better_outcome": float(handwritten_result.get("perspective_outcome", 0.0)),
							"worse_outcome": float(neural_result.get("perspective_outcome", 0.0)),
							"better_turns_after_branch": int(handwritten_result.get("turns_played_after_branch", 0)),
							"worse_turns_after_branch": int(neural_result.get("turns_played_after_branch", 0)),
							"better_leaf_terminal": bool(handwritten_result.get("leaf_terminal", false)),
							"worse_leaf_terminal": bool(neural_result.get("leaf_terminal", false)),
							"continuation_policy": PolicyContinuation.POLICY_NEURAL_VS_HANDWRITTEN,
							"priority_reasons": ["arena_divergence", "neural_selected_worse"],
							"source": source,
						})
						diagnostics.append({
							"game_id": game_id,
							"turn_index": turn_offset,
							"neural_group": neural_group,
							"neural_actions": neural_actions,
							"handwritten_actions": handwritten_actions,
							"opponent_actions": opponent_actions,
							"neural_outcome": float(neural_result.get("perspective_outcome", 0.0)),
							"handwritten_outcome": float(handwritten_result.get("perspective_outcome", 0.0)),
							"pair_kind": str(comparison.get("pair_kind", "")),
						})
						emitted_for_game = true
						break

			var actual_next_variant: Variant = _simulate_branch(
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
		if emitted_for_game:
			continue

	var manifest := {
		"manifest_schema_version": MANIFEST_SCHEMA_VERSION,
		"pair_schema_version": PAIR_SCHEMA_VERSION,
		"arena_preset": preset,
		"arena_profile": profile,
		"games_considered": games_considered,
		"divergences_considered": divergences_considered,
		"pairs_written": pairs.size(),
		"branch_unlabeled": branch_unlabeled,
		"no_preference": no_preference,
		"neural_better": neural_better,
		"invalid": invalid,
		"continuation_policy": PolicyContinuation.POLICY_NEURAL_VS_HANDWRITTEN,
		"same_actual_opponent_action": true,
		"first_useful_divergence_per_game": true,
	}
	var ok: bool = _write_text(out_dir.path_join("arena_hard_negative_pairs.jsonl"), _to_jsonl(pairs))
	ok = _write_text(out_dir.path_join("arena_divergences.jsonl"), _to_jsonl(diagnostics)) and ok
	ok = _write_text(
		out_dir.path_join("arena_hard_negative_manifest.json"),
		JSON.stringify(manifest, "  ") + "\n"
	) and ok
	print("[arena-hard-negatives] games=%d divergences=%d pairs=%d unlabeled=%d no_preference=%d neural_better=%d invalid=%d" % [
		games_considered,
		divergences_considered,
		pairs.size(),
		branch_unlabeled,
		no_preference,
		neural_better,
		invalid,
	])
	PureStateNeuralEvaluator.shutdown()
	get_tree().quit(0 if ok and invalid == 0 else 1)


func _simulate_branch(
	state: Dictionary,
	group_a: String,
	actions_a: Array,
	group_b: String,
	actions_b: Array,
	command_hexes: Dictionary
) -> Variant:
	var submitted: Dictionary = PureStateGameRollout._submitted_actions(
		state,
		group_a,
		actions_a,
		group_b,
		actions_b
	)
	var simulation: Dictionary = PureStateSimulator.simulate_turn(state, submitted)
	var next_variant: Variant = simulation.get("next_state", {})
	if not (next_variant is Dictionary) or (next_variant as Dictionary).is_empty():
		return null
	var next_state: Dictionary = (next_variant as Dictionary).duplicate(true)
	next_state["command_hexes"] = command_hexes.duplicate(true)
	return next_state


func _find_named_files(root: String, target_name: String, out: Array[String]) -> void:
	var dir: DirAccess = DirAccess.open(root)
	if dir == null:
		return
	dir.list_dir_begin()
	while true:
		var name: String = dir.get_next()
		if name.is_empty():
			break
		if name in [".", ".."]:
			continue
		var path: String = root.path_join(name)
		if dir.current_is_dir():
			_find_named_files(path, target_name, out)
		elif name == target_name:
			out.append(path)
	dir.list_dir_end()


func _read_json(path: String) -> Variant:
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		return null
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	file.close()
	return parsed


func _read_jsonl(path: String) -> Variant:
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
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
