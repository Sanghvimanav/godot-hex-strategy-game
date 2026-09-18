extends Node
## Tiny-curriculum self-play using full-coverage autoregressive PUCT.
##
## Every scenario is trained in all six rotations. Policy targets are per-unit MCTS
## visit distributions; value examples are labeled only from the completed self-play
## game's final result (elimination, configured survival objective, or draw).

const PureStateSelfPlaySuite = preload("res://src/simulation/pure_state_self_play_suite.gd")
const PureStateAutoregressivePUCT = preload("res://src/simulation/pure_state_autoregressive_puct.gd")
const PureStateSimulator = preload("res://src/simulation/pure_state_simulator.gd")
const PureStateTrainingData = preload("res://src/simulation/pure_state_training_data.gd")
const PureStateNeuralEvaluator = preload("res://src/simulation/pure_state_neural_evaluator.gd")
const PureStateJointPolicy = preload("res://src/simulation/pure_state_joint_policy.gd")

const ROTATIONS := [0, 1, 2, 3, 4, 5]
const SCENARIOS := [
	{"id": "basic_1", "marines": 1, "zerglings": 2, "max_turns": 3, "turn_limit_winner": "terran"},
	{"id": "basic_2", "marines": 3, "zerglings": 2, "max_turns": 8, "turn_limit_winner": "zerg"},
	{"id": "basic_3", "marines": 2, "zerglings": 4, "max_turns": 4, "turn_limit_winner": "terran"},
]
const DEFAULT_REPETITIONS := 2
const DEFAULT_PUCT_SIMULATIONS := 24
const DEFAULT_ROLLOUT_DEPTH := 3
const DEFAULT_PUCT_C := 1.5


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	var args := _parse_cmdline_kv()
	var checkpoint := str(args.get("checkpoint", ""))
	var out_dir := str(args.get("out", "user://tiny_mcts_self_play"))
	var rotation := int(args.get("rotation", "-1"))
	var repetitions := maxi(1, int(args.get("repetitions", str(DEFAULT_REPETITIONS))))
	var simulations := maxi(1, int(args.get("puct-simulations", str(DEFAULT_PUCT_SIMULATIONS))))
	var rollout_depth := maxi(1, int(args.get("rollout-depth", str(DEFAULT_ROLLOUT_DEPTH))))
	var c_puct := maxf(0.0, float(args.get("puct-c", str(DEFAULT_PUCT_C))))
	var generation := str(args.get("generation", "g0"))
	var seed_base := int(args.get("seed-base", "420000"))
	if checkpoint.is_empty():
		push_error("--checkpoint is required")
		get_tree().quit(1)
		return
	if rotation not in ROTATIONS:
		push_error("--rotation must be one of 0..5; got %d" % rotation)
		get_tree().quit(1)
		return

	var abs_out := ProjectSettings.globalize_path(out_dir)
	if DirAccess.make_dir_recursive_absolute(abs_out) != OK:
		push_error("Unable to create output directory: %s" % abs_out)
		get_tree().quit(1)
		return

	var policy_targets: Array = []
	var value_examples: Array = []
	var games: Array = []
	var outcomes := {"terran": 0, "zerg": 0, "draw": 0}
	var min_exposure_coverage := 1.0
	var min_visit_coverage := 1.0
	var zero_visit_action_count := 0
	var failed := false

	for scenario_index in range(SCENARIOS.size()):
		var scenario: Dictionary = SCENARIOS[scenario_index]
		for repetition in range(repetitions):
			var game_seed := seed_base + rotation * 10000 + scenario_index * 1000 + repetition * 37
			var game_result := _play_game(
				scenario,
				rotation,
				repetition,
				generation,
				game_seed,
				checkpoint,
				simulations,
				rollout_depth,
				c_puct
			)
			if not bool(game_result.get("valid", false)):
				push_error("Self-play failed: %s" % str(game_result))
				failed = true
				break
			for row_variant in game_result.get("policy_targets", []):
				if row_variant is Dictionary:
					policy_targets.append(row_variant)
			for example_variant in game_result.get("value_examples", []):
				if example_variant is Dictionary:
					value_examples.append(example_variant)
			games.append((game_result.get("game", {}) as Dictionary).duplicate(true))
			var winner := str(game_result.get("winner", ""))
			if winner in ["terran", "zerg"]:
				outcomes[winner] = int(outcomes[winner]) + 1
			else:
				outcomes["draw"] = int(outcomes["draw"]) + 1
			min_exposure_coverage = minf(min_exposure_coverage, float(game_result.get("min_exposure_coverage", 1.0)))
			min_visit_coverage = minf(min_visit_coverage, float(game_result.get("min_visit_coverage", 1.0)))
			zero_visit_action_count += int(game_result.get("zero_visit_action_count", 0))
		if failed:
			break

	var coverage_ok := is_equal_approx(min_exposure_coverage, 1.0) and is_equal_approx(min_visit_coverage, 1.0) and zero_visit_action_count == 0
	var manifest := {
		"schema_version": 1,
		"dataset": "tiny_autoregressive_puct_self_play_v1",
		"generation": generation,
		"checkpoint": checkpoint,
		"rotation": rotation,
		"training_rotations": ROTATIONS,
		"train_on_all_six_rotations": true,
		"scenarios": SCENARIOS,
		"repetitions": repetitions,
		"puct_simulations": simulations,
		"rollout_depth": rollout_depth,
		"puct_c": c_puct,
		"policy_target_source": "mcts_visit_distribution_only",
		"value_target_source": "final_self_play_result",
		"explicit_action_mechanics": false,
		"game_count": games.size(),
		"policy_prefix_count": policy_targets.size(),
		"value_example_count": value_examples.size(),
		"outcomes": outcomes,
		"minimum_exposure_coverage": min_exposure_coverage,
		"minimum_visit_coverage": min_visit_coverage,
		"zero_visit_action_count": zero_visit_action_count,
		"coverage_requirement": 1.0,
		"coverage_ok": coverage_ok,
	}
	var ok := _write_jsonl(abs_out.path_join("policy_targets.jsonl"), policy_targets)
	ok = _write_jsonl(abs_out.path_join("value_examples.jsonl"), value_examples) and ok
	ok = _write_jsonl(abs_out.path_join("games.jsonl"), games) and ok
	ok = _write_json(abs_out.path_join("manifest.json"), manifest) and ok
	print("[tiny-mcts-self-play] generation=%s rotation=%d games=%d prefixes=%d values=%d coverage=%.3f/%.3f outcomes=%s" % [
		generation,
		rotation,
		games.size(),
		policy_targets.size(),
		value_examples.size(),
		min_exposure_coverage,
		min_visit_coverage,
		str(outcomes),
	])
	_shutdown()
	get_tree().quit(0 if ok and not failed and coverage_ok else 1)


func _play_game(
	scenario: Dictionary,
	rotation: int,
	repetition: int,
	generation: String,
	game_seed: int,
	checkpoint: String,
	simulations: int,
	rollout_depth: int,
	c_puct: float
) -> Dictionary:
	var marines := int(scenario.get("marines", 0))
	var zerglings := int(scenario.get("zerglings", 0))
	var max_turns := int(scenario.get("max_turns", 1))
	var turn_limit_winner := str(scenario.get("turn_limit_winner", ""))
	var scenario_id := str(scenario.get("id", "basic"))
	var game_id := "%s-%s-r%d-rep%d-s%d" % [generation, scenario_id, rotation, repetition, game_seed]
	var state := PureStateSelfPlaySuite.basic_state(
		marines,
		zerglings,
		rotation,
		max_turns,
		turn_limit_winner,
		false
	)
	state["scenario_id"] = game_id
	state["turn_index"] = 0
	var history: Array = []
	var targets: Array = []
	var min_exposure_coverage := 1.0
	var min_visit_coverage := 1.0
	var zero_visit_action_count := 0
	var status := "turn_limit"
	var winner := ""

	for turn_index in range(max_turns):
		state["turn_index"] = turn_index
		var before := state.duplicate(true)
		var terran := PureStateAutoregressivePUCT.choose_plan(
			before,
			"terran",
			"zerg",
			checkpoint,
			{
				"puct_simulations": simulations,
				"rollout_depth": rollout_depth,
				"puct_c": c_puct,
				"seed": game_seed + turn_index * 101 + 11,
			}
		)
		var zerg := PureStateAutoregressivePUCT.choose_plan(
			before,
			"zerg",
			"terran",
			checkpoint,
			{
				"puct_simulations": simulations,
				"rollout_depth": rollout_depth,
				"puct_c": c_puct,
				"seed": game_seed + turn_index * 101 + 53,
			}
		)
		if not bool(terran.get("valid", false)) or not bool(zerg.get("valid", false)):
			return {"valid": false, "error": "prefix_puct_decision_failed", "terran": terran, "zerg": zerg}
		for faction_result_variant in [terran, zerg]:
			var faction_result: Dictionary = faction_result_variant
			min_exposure_coverage = minf(min_exposure_coverage, float(faction_result.get("min_exposure_coverage", 1.0)))
			min_visit_coverage = minf(min_visit_coverage, float(faction_result.get("min_visit_coverage", 1.0)))
			zero_visit_action_count += int(faction_result.get("zero_visit_action_count", 0))
			for target_variant in faction_result.get("prefix_targets", []):
				if not (target_variant is Dictionary):
					continue
				var target: Dictionary = (target_variant as Dictionary).duplicate(true)
				target["game_id"] = game_id
				target["turn_index"] = turn_index
				target["rotation_steps"] = rotation
				target["scenario_family"] = scenario_id
				target["generation"] = generation
				target["source"] = {
					"dataset": "tiny_autoregressive_puct_self_play_v1",
					"generation": generation,
					"rotation_steps": rotation,
					"scenario_family": scenario_id,
					"train_on_all_six_rotations": true,
				}
				targets.append(target)

		var terran_actions: Array = (terran.get("actions", []) as Array).duplicate(true)
		var zerg_actions: Array = (zerg.get("actions", []) as Array).duplicate(true)
		var simulation := PureStateSimulator.simulate_turn(before, {
			"terran": terran_actions,
			"zerg": zerg_actions,
		})
		var next_variant = simulation.get("next_state", {})
		if not (next_variant is Dictionary) or (next_variant as Dictionary).is_empty():
			return {"valid": false, "error": "game_simulation_failed", "turn": turn_index}
		var next_state: Dictionary = (next_variant as Dictionary).duplicate(true)
		next_state["turn_index"] = turn_index + 1
		history.append({
			"turn": turn_index + 1,
			"state_before": before,
			"terran_actions": terran_actions,
			"zerg_actions": zerg_actions,
		})
		state = next_state
		var terran_alive := _alive_count(state, "terran")
		var zerg_alive := _alive_count(state, "zerg")
		if terran_alive <= 0 or zerg_alive <= 0:
			status = "terminal"
			if terran_alive > 0 and zerg_alive <= 0:
				winner = "terran"
			elif zerg_alive > 0 and terran_alive <= 0:
				winner = "zerg"
			else:
				winner = ""
			break

	if status == "turn_limit":
		winner = turn_limit_winner
	var rollout := {
		"valid": true,
		"status": status,
		"winner": winner,
		"termination_reason": "elimination" if status == "terminal" else "turn_limit",
		"turns_played": history.size(),
		"max_non_progress_streak": 0,
		"history": history,
		"final_state": state.duplicate(true),
	}
	var source := {
		"dataset": "tiny_autoregressive_puct_self_play_v1",
		"generation": generation,
		"rotation_steps": rotation,
		"scenario_family": scenario_id,
		"game_seed": game_seed,
		"train_on_all_six_rotations": true,
		"value_target_source": "final_self_play_result",
		"reward_discount": 1.0,
		"label_unresolved_as_draw": true,
		"explicit_action_mechanics": false,
	}
	var built := PureStateTrainingData.build_examples_from_rollout(
		rollout,
		"terran",
		"zerg",
		game_id,
		source
	)
	if not bool(built.get("valid", false)) or not bool(built.get("labeled", false)):
		return {"valid": false, "error": "final_outcome_value_labeling_failed", "detail": built}
	return {
		"valid": true,
		"winner": winner,
		"policy_targets": targets,
		"value_examples": (built.get("examples", []) as Array).duplicate(true),
		"min_exposure_coverage": min_exposure_coverage,
		"min_visit_coverage": min_visit_coverage,
		"zero_visit_action_count": zero_visit_action_count,
		"game": {
			"game_id": game_id,
			"generation": generation,
			"scenario_family": scenario_id,
			"rotation_steps": rotation,
			"repetition": repetition,
			"game_seed": game_seed,
			"marines": marines,
			"zerglings": zerglings,
			"max_turns": max_turns,
			"status": status,
			"winner": winner,
			"turns_played": history.size(),
			"policy_prefix_count": targets.size(),
			"value_example_count": int(built.get("example_count", 0)),
			"minimum_exposure_coverage": min_exposure_coverage,
			"minimum_visit_coverage": min_visit_coverage,
			"zero_visit_action_count": zero_visit_action_count,
		},
	}


func _alive_count(state: Dictionary, group_name: String) -> int:
	for group_variant in state.get("groups", []):
		if not (group_variant is Dictionary):
			continue
		var group: Dictionary = group_variant
		if str(group.get("name", "")) != group_name:
			continue
		var count := 0
		for unit_variant in group.get("units", []):
			if unit_variant is Dictionary and int((unit_variant as Dictionary).get("health", 0)) > 0:
				count += 1
		return count
	return 0


func _write_json(path: String, value: Variant) -> bool:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_error("Unable to write %s" % path)
		return false
	file.store_string(JSON.stringify(value, "  ") + "\n")
	file.close()
	return true


func _write_jsonl(path: String, rows: Array) -> bool:
	var lines: PackedStringArray = []
	for row_variant in rows:
		if row_variant is Dictionary:
			lines.append(JSON.stringify(row_variant))
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_error("Unable to write %s" % path)
		return false
	file.store_string("\n".join(lines) + ("\n" if not lines.is_empty() else ""))
	file.close()
	return true


func _shutdown() -> void:
	PureStateNeuralEvaluator.shutdown()
	PureStateJointPolicy.shutdown()


func _parse_cmdline_kv() -> Dictionary:
	var result: Dictionary = {}
	var raw := OS.get_cmdline_user_args()
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
