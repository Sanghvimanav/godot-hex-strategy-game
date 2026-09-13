extends Node
## Focused MCTS-1 validation on the known 2 Marines vs 1 Zergling pathology.
##
## Uses the same trained value+policy checkpoint for both search arms:
## - baseline: current bounded robust opponent-response search
## - candidate: simultaneous root PUCT over neural plan priors
##
## This is intentionally not a promotion experiment. It validates simultaneous
## semantics, deterministic visit accounting, search-only behavior, and whether
## root PUCT changes M2Z1 conversion before multi-turn MCTS is added.

const GameplayAI = preload("res://src/battle/ai/gameplay_ai.gd")
const PureStateSelfPlaySuite = preload("res://src/simulation/pure_state_self_play_suite.gd")
const PureStateGameRollout = preload("res://src/simulation/pure_state_game_rollout.gd")
const PureStateNeuralEvaluator = preload("res://src/simulation/pure_state_neural_evaluator.gd")
const PureStateJointPolicy = preload("res://src/simulation/pure_state_joint_policy.gd")

const ROTATIONS := [1, 3, 5]
const MAX_ACTIONS_PER_UNIT := 8
const PLAN_BUDGET := 4
const MAX_TURNS := 8
const PUCT_SIMULATIONS := 16
const PUCT_C := 1.5


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	var args := _parse_cmdline_kv()
	var checkpoint := str(args.get("checkpoint", ""))
	var out_path := str(args.get("out", "user://m2z1_puct_diagnostic.json"))
	if checkpoint.is_empty():
		push_error("--checkpoint is required")
		get_tree().quit(1)
		return

	var robust_settings := GameplayAI.neural_settings(
		MAX_ACTIONS_PER_UNIT,
		PLAN_BUDGET,
		MAX_ACTIONS_PER_UNIT,
		PLAN_BUDGET,
		checkpoint,
		{"learned_proposals": true}
	)
	var puct_settings := GameplayAI.neural_puct_settings(
		MAX_ACTIONS_PER_UNIT,
		PLAN_BUDGET,
		MAX_ACTIONS_PER_UNIT,
		PLAN_BUDGET,
		checkpoint,
		{
			"puct_policy_source": "neural",
			"puct_simulations": PUCT_SIMULATIONS,
			"puct_c": PUCT_C,
			"puct_value_scale": 1000.0,
		}
	)
	var handwritten_zerg := GameplayAI.handwritten_settings(
		MAX_ACTIONS_PER_UNIT,
		PLAN_BUDGET,
		MAX_ACTIONS_PER_UNIT,
		PLAN_BUDGET
	)

	var rows: Array = []
	var all_valid := true
	var all_deterministic := true
	var all_visit_accounting := true
	var robust_wins := 0
	var puct_wins := 0

	for rotation_variant in ROTATIONS:
		var rotation := int(rotation_variant)
		var initial_state := PureStateSelfPlaySuite.basic_state(2, 1, rotation, MAX_TURNS, "", false)
		var before := initial_state.duplicate(true)

		var puct_first := GameplayAI.choose_actions(initial_state, "terran", "zerg", puct_settings)
		var puct_second := GameplayAI.choose_actions(initial_state, "terran", "zerg", puct_settings)
		var deterministic := _same_puct_decision(puct_first, puct_second)
		var visit_accounting := _visit_accounting_ok(puct_first, PUCT_SIMULATIONS)
		var source_unchanged := initial_state == before
		all_deterministic = all_deterministic and deterministic
		all_visit_accounting = all_visit_accounting and visit_accounting
		all_valid = all_valid and bool(puct_first.get("valid", false)) and bool(puct_second.get("valid", false)) and source_unchanged

		var robust_initial := GameplayAI.choose_actions(initial_state, "terran", "zerg", robust_settings)
		all_valid = all_valid and bool(robust_initial.get("valid", false))

		var robust_rollout := PureStateGameRollout.play_game_with_settings(
			initial_state,
			"terran",
			"zerg",
			robust_settings,
			handwritten_zerg,
			MAX_TURNS,
			true,
			""
		)
		var puct_rollout := PureStateGameRollout.play_game_with_settings(
			initial_state,
			"terran",
			"zerg",
			puct_settings,
			handwritten_zerg,
			MAX_TURNS,
			true,
			""
		)
		all_valid = all_valid and bool(robust_rollout.get("valid", false)) and bool(puct_rollout.get("valid", false))
		if str(robust_rollout.get("winner", "")) == "terran":
			robust_wins += 1
		if str(puct_rollout.get("winner", "")) == "terran":
			puct_wins += 1

		rows.append({
			"rotation": rotation,
			"source_state_unchanged": source_unchanged,
			"puct_deterministic": deterministic,
			"puct_visit_accounting": visit_accounting,
			"initial_decisions_differ": puct_first.get("actions", []) != robust_initial.get("actions", []),
			"robust_initial_actions": (robust_initial.get("actions", []) as Array).duplicate(true),
			"puct_initial_actions": (puct_first.get("actions", []) as Array).duplicate(true),
			"puct_initial": _summarize_puct_decision(puct_first),
			"robust_rollout": _summarize_rollout(robust_rollout),
			"puct_rollout": _summarize_rollout(puct_rollout),
		})

	var report := {
		"experiment": "m2z1_simultaneous_puct_mcts1",
		"mcts_stage": "MCTS-1",
		"checkpoint": checkpoint,
		"rotations": ROTATIONS,
		"plan_budget_per_side": PLAN_BUDGET,
		"puct_simulations": PUCT_SIMULATIONS,
		"puct_c": PUCT_C,
		"all_decisions_and_rollouts_valid": all_valid,
		"deterministic": all_deterministic,
		"visit_accounting_valid": all_visit_accounting,
		"implementation_ready": all_valid and all_deterministic and all_visit_accounting,
		"robust_terran_wins": robust_wins,
		"puct_terran_wins": puct_wins,
		"rows": rows,
	}
	var ok := _write_json(out_path, report)
	print(JSON.stringify(report))
	PureStateNeuralEvaluator.shutdown()
	PureStateJointPolicy.shutdown()
	get_tree().quit(0 if ok and bool(report.get("implementation_ready", false)) else 1)


func _same_puct_decision(a: Dictionary, b: Dictionary) -> bool:
	if not bool(a.get("valid", false)) or not bool(b.get("valid", false)):
		return false
	if a.get("actions", []) != b.get("actions", []):
		return false
	var ad: Dictionary = a.get("diagnostics", {})
	var bd: Dictionary = b.get("diagnostics", {})
	return _stable_edges(ad.get("own_edge_stats", [])) == _stable_edges(bd.get("own_edge_stats", [])) \
		and _stable_edges(ad.get("opponent_edge_stats", [])) == _stable_edges(bd.get("opponent_edge_stats", []))


func _stable_edges(edges_variant: Variant) -> Array:
	var result: Array = []
	if not (edges_variant is Array):
		return result
	for edge_variant in edges_variant:
		if not (edge_variant is Dictionary):
			continue
		var edge: Dictionary = edge_variant
		result.append({
			"actions": (edge.get("actions", []) as Array).duplicate(true),
			"prior": float(edge.get("prior", 0.0)),
			"visits": int(edge.get("visits", 0)),
			"q": float(edge.get("q", 0.0)),
			"raw_q": float(edge.get("raw_q", 0.0)),
		})
	return result


func _visit_accounting_ok(decision: Dictionary, expected: int) -> bool:
	if not bool(decision.get("valid", false)):
		return false
	var diagnostics: Dictionary = decision.get("diagnostics", {})
	if int(diagnostics.get("simulations_run", -1)) != expected:
		return false
	var own_total := 0
	for edge_variant in diagnostics.get("own_edge_stats", []):
		if edge_variant is Dictionary:
			own_total += int((edge_variant as Dictionary).get("visits", 0))
	var opponent_total := 0
	for edge_variant in diagnostics.get("opponent_edge_stats", []):
		if edge_variant is Dictionary:
			opponent_total += int((edge_variant as Dictionary).get("visits", 0))
	var pair_total := 0
	for row_variant in diagnostics.get("pair_stats", []):
		if row_variant is Dictionary:
			pair_total += int((row_variant as Dictionary).get("visits", 0))
	return own_total == expected and opponent_total == expected and pair_total == expected


func _summarize_puct_decision(decision: Dictionary) -> Dictionary:
	if not bool(decision.get("valid", false)):
		return {"valid": false, "error": str(decision.get("error", "")), "diagnostics": decision.get("diagnostics", {})}
	var diagnostics: Dictionary = decision.get("diagnostics", {})
	return {
		"valid": true,
		"search_type": str(diagnostics.get("search_type", "")),
		"mcts_stage": str(diagnostics.get("mcts_stage", "")),
		"simultaneous_pre_turn": bool(diagnostics.get("simultaneous_pre_turn", false)),
		"simulations_run": int(diagnostics.get("simulations_run", 0)),
		"elapsed_ms": float(diagnostics.get("elapsed_ms", 0.0)),
		"selected_actions": (decision.get("actions", []) as Array).duplicate(true),
		"own_edge_stats": _stable_edges(diagnostics.get("own_edge_stats", [])),
		"opponent_edge_stats": _stable_edges(diagnostics.get("opponent_edge_stats", [])),
		"pair_stats": (diagnostics.get("pair_stats", []) as Array).duplicate(true),
	}


func _summarize_rollout(rollout: Dictionary) -> Dictionary:
	var terran_simulations := 0
	var terran_elapsed_ms := 0.0
	for turn_variant in rollout.get("history", []):
		if not (turn_variant is Dictionary):
			continue
		var turn: Dictionary = turn_variant
		terran_simulations += int(turn.get("terran_search_simulations", 0))
		terran_elapsed_ms += float(turn.get("terran_search_elapsed_ms", 0.0))
	return {
		"valid": bool(rollout.get("valid", false)),
		"status": str(rollout.get("status", "")),
		"winner": str(rollout.get("winner", "")),
		"turns_played": int(rollout.get("turns_played", 0)),
		"termination_reason": str(rollout.get("termination_reason", "")),
		"terran_search_simulations": terran_simulations,
		"terran_search_elapsed_ms": terran_elapsed_ms,
	}


func _write_json(path: String, value: Variant) -> bool:
	var absolute := path if path.is_absolute_path() else ProjectSettings.globalize_path(path)
	var dir_path := absolute.get_base_dir()
	if DirAccess.make_dir_recursive_absolute(dir_path) != OK:
		push_error("Unable to create diagnostic output directory: %s" % dir_path)
		return false
	var file := FileAccess.open(absolute, FileAccess.WRITE)
	if file == null:
		push_error("Unable to write diagnostic output: %s" % absolute)
		return false
	file.store_string(JSON.stringify(value, "  ") + "\n")
	file.close()
	return true


func _parse_cmdline_kv() -> Dictionary:
	var result: Dictionary = {}
	var raw := OS.get_cmdline_user_args()
	if raw.is_empty():
		raw = OS.get_cmdline_args()
	for raw_variant in raw:
		var arg := str(raw_variant).strip_edges()
		if arg.begins_with("--"):
			arg = arg.substr(2)
		if not arg.contains("="):
			continue
		var parts := arg.split("=", true, 1)
		if parts.size() == 2:
			result[parts[0]] = parts[1]
	return result
