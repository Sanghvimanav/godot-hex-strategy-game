extends Node
## Generate simultaneous MCTS-2 visit targets for the known 2 Marines vs 1 Zergling
## conversion drill. Training rotations are supplied explicitly by the workflow and
## must remain a subset of 0/2/4; held-out rotations 1/3/5 are rejected so policy
## supervision cannot leak evaluation geometry.

const GameplayAI = preload("res://src/battle/ai/gameplay_ai.gd")
const PureStateSelfPlaySuite = preload("res://src/simulation/pure_state_self_play_suite.gd")
const PureStateSimulator = preload("res://src/simulation/pure_state_simulator.gd")
const PureStateNeuralEvaluator = preload("res://src/simulation/pure_state_neural_evaluator.gd")
const PureStateJointPolicy = preload("res://src/simulation/pure_state_joint_policy.gd")

const TRAINING_ROTATIONS := [0, 2, 4]
const MAX_ACTIONS_PER_UNIT := 8
const PLAN_BUDGET := 4
const DEFAULT_MAX_TURNS := 6
const DEFAULT_PUCT_SIMULATIONS := 24
const DEFAULT_PUCT_MAX_DEPTH := 3
const DEFAULT_PUCT_C := 1.5


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	var args := _parse_cmdline_kv()
	var checkpoint := str(args.get("checkpoint", ""))
	var out_dir := str(args.get("out", "user://mcts_visit_training_targets"))
	var rotation := int(args.get("rotation", "-1"))
	var max_turns := maxi(1, int(args.get("max-turns", str(DEFAULT_MAX_TURNS))))
	var simulations := maxi(1, int(args.get("puct-simulations", str(DEFAULT_PUCT_SIMULATIONS))))
	var max_depth := maxi(2, int(args.get("puct-max-depth", str(DEFAULT_PUCT_MAX_DEPTH))))
	var c_puct := maxf(0.0, float(args.get("puct-c", str(DEFAULT_PUCT_C))))
	if checkpoint.is_empty():
		push_error("--checkpoint is required")
		get_tree().quit(1)
		return
	if rotation not in TRAINING_ROTATIONS:
		push_error("MCTS policy targets may use only training rotations 0/2/4; got %d" % rotation)
		get_tree().quit(1)
		return

	var settings := GameplayAI.neural_puct_settings(
		MAX_ACTIONS_PER_UNIT,
		PLAN_BUDGET,
		MAX_ACTIONS_PER_UNIT,
		PLAN_BUDGET,
		checkpoint,
		{
			"learned_proposals": true,
			"puct_policy_source": "neural",
			"puct_simulations": simulations,
			"puct_max_depth": max_depth,
			"puct_c": c_puct,
			"puct_value_scale": 1000.0,
		}
	)
	var state := PureStateSelfPlaySuite.basic_state(2, 1, rotation, 8, "", false)
	state["turn_index"] = 0
	var rows: Array = []
	var turn_summaries: Array = []
	var status := "turn_limit"
	var winner := ""

	for turn_index in range(max_turns):
		state["turn_index"] = turn_index
		var terran_decision := GameplayAI.choose_actions(state, "terran", "zerg", settings)
		var zerg_decision := GameplayAI.choose_actions(state, "zerg", "terran", settings)
		if not bool(terran_decision.get("valid", false)) or not bool(zerg_decision.get("valid", false)):
			push_error("MCTS decision failed at turn %d" % turn_index)
			_shutdown()
			get_tree().quit(1)
			return
		var terran_row := _decision_row(state, terran_decision, "terran", "zerg", rotation, turn_index, simulations, max_depth)
		var zerg_row := _decision_row(state, zerg_decision, "zerg", "terran", rotation, turn_index, simulations, max_depth)
		if not bool(terran_row.get("valid", false)) or not bool(zerg_row.get("valid", false)):
			push_error("MCTS visit capture failed at turn %d" % turn_index)
			_shutdown()
			get_tree().quit(1)
			return
		rows.append(terran_row)
		rows.append(zerg_row)

		var terran_actions: Array = (terran_decision.get("actions", []) as Array).duplicate(true)
		var zerg_actions: Array = (zerg_decision.get("actions", []) as Array).duplicate(true)
		var submitted := {"terran": terran_actions, "zerg": zerg_actions}
		var simulation := PureStateSimulator.simulate_turn(state, submitted)
		var next_state_variant = simulation.get("next_state", {})
		if not (next_state_variant is Dictionary) or (next_state_variant as Dictionary).is_empty():
			push_error("Simulation failed at turn %d" % turn_index)
			_shutdown()
			get_tree().quit(1)
			return
		var next_state: Dictionary = (next_state_variant as Dictionary).duplicate(true)
		next_state["turn_index"] = turn_index + 1
		var terran_alive := _alive_count(next_state, "terran")
		var zerg_alive := _alive_count(next_state, "zerg")
		turn_summaries.append({
			"turn": turn_index + 1,
			"terran_alive": terran_alive,
			"zerg_alive": zerg_alive,
			"terran_actions": terran_actions,
			"zerg_actions": zerg_actions,
		})
		state = next_state
		if terran_alive <= 0 or zerg_alive <= 0:
			status = "terminal"
			winner = "zerg" if terran_alive <= 0 and zerg_alive > 0 else ("terran" if zerg_alive <= 0 and terran_alive > 0 else "")
			break

	var abs_out := ProjectSettings.globalize_path(out_dir)
	if DirAccess.make_dir_recursive_absolute(abs_out) != OK:
		push_error("Unable to create output directory: %s" % abs_out)
		_shutdown()
		get_tree().quit(1)
		return
	var manifest := {
		"schema_version": 1,
		"dataset": "mcts_visit_training_m2z1",
		"checkpoint": checkpoint,
		"training_rotation": rotation,
		"heldout_rotations_excluded": [1, 3, 5],
		"marines": 2,
		"zerglings": 1,
		"max_turns": max_turns,
		"puct_simulations": simulations,
		"puct_max_depth": max_depth,
		"puct_c": c_puct,
		"decision_count": rows.size(),
		"status": status,
		"winner": winner,
		"turns_played": turn_summaries.size(),
		"turns": turn_summaries,
	}
	var ok := _write_jsonl(out_dir.path_join("search_decisions.jsonl"), rows)
	ok = _write_json(out_dir.path_join("manifest.json"), manifest) and ok
	print("[mcts-visit-targets] rotation=%d decisions=%d turns=%d status=%s winner=%s" % [rotation, rows.size(), turn_summaries.size(), status, winner])
	_shutdown()
	get_tree().quit(0 if ok else 1)


func _decision_row(
	state: Dictionary,
	decision: Dictionary,
	group_name: String,
	opponent_group: String,
	rotation: int,
	turn_index: int,
	expected_simulations: int,
	expected_depth: int
) -> Dictionary:
	var diagnostics: Dictionary = decision.get("diagnostics", {})
	var visits_variant = diagnostics.get("root_visit_distribution", [])
	if str(diagnostics.get("mcts_stage", "")) != "MCTS-2":
		return {"valid": false, "error": "mcts2_required"}
	if not bool(diagnostics.get("simultaneous_pre_turn", false)):
		return {"valid": false, "error": "simultaneous_pre_turn_required"}
	if int(diagnostics.get("puct_max_depth", 0)) != expected_depth:
		return {"valid": false, "error": "depth_mismatch"}
	if not (visits_variant is Array) or (visits_variant as Array).is_empty():
		return {"valid": false, "error": "missing_root_visit_distribution"}
	var visit_total := 0
	for visit_variant in visits_variant:
		if visit_variant is Dictionary:
			visit_total += int((visit_variant as Dictionary).get("visits", 0))
	var simulations_run := int(diagnostics.get("simulations_run", 0))
	if simulations_run <= 0 or visit_total != simulations_run:
		return {"valid": false, "error": "visit_accounting_mismatch"}
	if simulations_run > expected_simulations:
		return {"valid": false, "error": "simulation_budget_exceeded"}
	return {
		"valid": true,
		"schema_version": 2,
		"game_id": "m2z1-r%d-mcts2-%s" % [rotation, group_name],
		"turn_index": turn_index,
		"perspective_group": group_name,
		"opponent_group": opponent_group,
		"starting_state": state.duplicate(true),
		"selected_actions": (decision.get("actions", []) as Array).duplicate(true),
		"mcts_stage": "MCTS-2",
		"mcts_search_type": str(diagnostics.get("search_type", "")),
		"mcts_simulations": simulations_run,
		"mcts_max_depth": expected_depth,
		"mcts_visit_distribution": (visits_variant as Array).duplicate(true),
		"source": {
			"dataset": "mcts_visit_training_m2z1",
			"search_decision_policy": "mcts_visit_distribution",
			"rotation_steps": rotation,
			"training_rotation": true,
			"heldout_rotation": false,
			"marines": 2,
			"zerglings": 1,
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
	var file := FileAccess.open(ProjectSettings.globalize_path(path), FileAccess.WRITE)
	if file == null:
		push_error("Unable to write %s" % path)
		return false
	file.store_string(JSON.stringify(value, "  ") + "\n")
	file.close()
	return true


func _write_jsonl(path: String, rows: Array) -> bool:
	var lines := PackedStringArray()
	for row in rows:
		lines.append(JSON.stringify(row))
	var file := FileAccess.open(ProjectSettings.globalize_path(path), FileAccess.WRITE)
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
