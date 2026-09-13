extends Node
## Focused diagnostic for the 2 Marines vs 1 Zergling conversion failure.
##
## Replays neural Terran vs handwritten Zerg on held-out rotations, compares
## split-fire availability at live candidate budgets against wider pools, and now
## validates the first simultaneous root-PUCT layer using the same checkpoint.

const GameplayAI = preload("res://src/battle/ai/gameplay_ai.gd")
const PureStateSelfPlaySuite = preload("res://src/simulation/pure_state_self_play_suite.gd")
const PureStateGameRollout = preload("res://src/simulation/pure_state_game_rollout.gd")
const PureStateSearchDecisionData = preload("res://src/simulation/pure_state_search_decision_data.gd")
const PureStateNeuralPlans = preload("res://src/simulation/pure_state_neural_plans.gd")
const PureStateNeuralEvaluator = preload("res://src/simulation/pure_state_neural_evaluator.gd")
const PureStateJointPolicy = preload("res://src/simulation/pure_state_joint_policy.gd")
const PureStateTrainingData = preload("res://src/simulation/pure_state_training_data.gd")

const ROTATIONS := [1, 3, 5]
const MAX_ACTIONS_PER_UNIT := 8
const LIVE_OWN_PLANS := 4
const LIVE_OPPONENT_PLANS := 4
const LIVE_NEURAL_PROPOSALS := 2
const EXPANDED_OWN_PLANS := 32
const EXPANDED_OPPONENT_PLANS := 16
const EXPANDED_NEURAL_PROPOSALS := 32
const MAX_TURNS := 8
const PUCT_SIMULATIONS := 16
const PUCT_C := 1.5


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	var args: Dictionary = _parse_cmdline_kv()
	var checkpoint: String = str(args.get("checkpoint", ""))
	var out_path: String = str(args.get("out", "user://m2z1_split_diagnostic.json"))
	if checkpoint.is_empty():
		push_error("--checkpoint is required")
		get_tree().quit(1)
		return

	if not _audit_unresolved_draw_target():
		get_tree().quit(1)
		return

	var neural_settings: Dictionary = GameplayAI.neural_settings(
		MAX_ACTIONS_PER_UNIT,
		LIVE_OWN_PLANS,
		MAX_ACTIONS_PER_UNIT,
		LIVE_OPPONENT_PLANS,
		checkpoint,
		{"learned_proposals": true}
	)
	var puct_settings: Dictionary = GameplayAI.neural_puct_settings(
		MAX_ACTIONS_PER_UNIT,
		LIVE_OWN_PLANS,
		MAX_ACTIONS_PER_UNIT,
		LIVE_OPPONENT_PLANS,
		checkpoint,
		{
			"puct_policy_source": "neural",
			"puct_simulations": PUCT_SIMULATIONS,
			"puct_c": PUCT_C,
			"puct_value_scale": 1000.0,
		}
	)
	var handwritten_settings: Dictionary = GameplayAI.handwritten_settings(
		MAX_ACTIONS_PER_UNIT,
		LIVE_OWN_PLANS,
		MAX_ACTIONS_PER_UNIT,
		LIVE_OPPONENT_PLANS
	)
	var evaluator_settings: Dictionary = neural_settings.get("evaluator_settings", {}) as Dictionary
	var rotations: Array = []
	var puct_ready := true
	var puct_terran_wins := 0
	var robust_terran_wins := 0

	for rotation_variant in ROTATIONS:
		var rotation: int = int(rotation_variant)
		var initial_state: Dictionary = PureStateSelfPlaySuite.basic_state(2, 1, rotation, MAX_TURNS, "", false)
		var initial_before := initial_state.duplicate(true)
		var rollout: Dictionary = PureStateGameRollout.play_game_with_settings(
			initial_state,
			"terran",
			"zerg",
			neural_settings,
			handwritten_settings,
			MAX_TURNS,
			true,
			""
		)
		if str(rollout.get("winner", "")) == "terran":
			robust_terran_wins += 1
		var turn_rows: Array = []
		var history: Array = rollout.get("history", []) as Array
		for history_index in range(history.size()):
			var turn_number: int = history_index + 1
			if turn_number < 2 or turn_number > 4:
				continue
			var turn_variant = history[history_index]
			if not (turn_variant is Dictionary):
				continue
			var turn: Dictionary = turn_variant
			var state_before_variant = turn.get("state_before", {})
			var selected_variant = turn.get("terran_actions", [])
			if not (state_before_variant is Dictionary) or not (selected_variant is Array):
				continue
			var state_before: Dictionary = (state_before_variant as Dictionary).duplicate(true)
			var selected_actions: Array = (selected_variant as Array).duplicate(true)

			var live_matrix: Dictionary = PureStateSearchDecisionData.capture_decision(
				state_before, "terran", "zerg", selected_actions,
				MAX_ACTIONS_PER_UNIT, LIVE_OWN_PLANS, LIVE_OPPONENT_PLANS,
				"m2z1-r%d-live" % rotation, turn_number, {}, {"diagnostic": true}
			)
			var expanded_matrix: Dictionary = PureStateSearchDecisionData.capture_decision(
				state_before, "terran", "zerg", selected_actions,
				MAX_ACTIONS_PER_UNIT, EXPANDED_OWN_PLANS, EXPANDED_OPPONENT_PLANS,
				"m2z1-r%d-expanded" % rotation, turn_number, {}, {"diagnostic": true}
			)
			var live_neural: Array = PureStateNeuralPlans.get_candidate_plans(
				state_before, "terran", "zerg", MAX_ACTIONS_PER_UNIT,
				LIVE_NEURAL_PROPOSALS, evaluator_settings
			)
			var expanded_neural: Array = PureStateNeuralPlans.get_candidate_plans(
				state_before, "terran", "zerg", MAX_ACTIONS_PER_UNIT,
				EXPANDED_NEURAL_PROPOSALS, evaluator_settings
			)
			turn_rows.append({
				"turn": turn_number,
				"selected_actions": selected_actions,
				"selected_is_split_fire": _is_split_fire(selected_actions),
				"live_search": _summarize_search_matrix(live_matrix),
				"expanded_search": _summarize_search_matrix(expanded_matrix),
				"live_neural_proposals": _summarize_neural_plans(live_neural),
				"expanded_neural_proposals": _summarize_neural_plans(expanded_neural),
			})

		# MCTS-1 validation is deliberately search-only: same checkpoint, same
		# simulator, same initial state. Repeat the root decision to prove stable
		# visit accounting before running the full 8-turn diagnostic rollout.
		var puct_first := GameplayAI.choose_actions(initial_state, "terran", "zerg", puct_settings)
		var puct_second := GameplayAI.choose_actions(initial_state, "terran", "zerg", puct_settings)
		var puct_deterministic := _same_puct_decision(puct_first, puct_second)
		var puct_visits_valid := _puct_visit_accounting_ok(puct_first, PUCT_SIMULATIONS)
		var source_unchanged := initial_state == initial_before
		var puct_rollout := PureStateGameRollout.play_game_with_settings(
			initial_state,
			"terran",
			"zerg",
			puct_settings,
			handwritten_settings,
			MAX_TURNS,
			true,
			""
		)
		var rotation_puct_ready := (
			bool(puct_first.get("valid", false))
			and bool(puct_second.get("valid", false))
			and bool(puct_rollout.get("valid", false))
			and puct_deterministic
			and puct_visits_valid
			and source_unchanged
		)
		puct_ready = puct_ready and rotation_puct_ready
		if str(puct_rollout.get("winner", "")) == "terran":
			puct_terran_wins += 1

		rotations.append({
			"rotation": rotation,
			"status": str(rollout.get("status", "")),
			"winner": str(rollout.get("winner", "")),
			"turns_played": int(rollout.get("turns_played", 0)),
			"termination_reason": str(rollout.get("termination_reason", "")),
			"turns": turn_rows,
			"mcts1": {
				"ready": rotation_puct_ready,
				"source_state_unchanged": source_unchanged,
				"deterministic": puct_deterministic,
				"visit_accounting_valid": puct_visits_valid,
				"initial_decision": _summarize_puct_decision(puct_first),
				"rollout": _summarize_rollout(puct_rollout),
			},
		})

	var report := {
		"scenario": "2_marines_vs_1_zergling",
		"live_budget": {
			"own_plans": LIVE_OWN_PLANS,
			"opponent_plans": LIVE_OPPONENT_PLANS,
			"neural_proposals": LIVE_NEURAL_PROPOSALS,
		},
		"expanded_budget": {
			"own_plans": EXPANDED_OWN_PLANS,
			"opponent_plans": EXPANDED_OPPONENT_PLANS,
			"neural_proposals": EXPANDED_NEURAL_PROPOSALS,
		},
		"unresolved_draw_target_audit": true,
		"mcts1": {
			"stage": "MCTS-1",
			"policy": GameplayAI.POLICY_SIMULTANEOUS_PUCT,
			"simulations_per_decision": PUCT_SIMULATIONS,
			"c_puct": PUCT_C,
			"implementation_ready": puct_ready,
			"robust_terran_wins": robust_terran_wins,
			"puct_terran_wins": puct_terran_wins,
		},
		"rotations": rotations,
	}
	var ok: bool = _write_json(out_path, report)
	print(JSON.stringify(report))
	PureStateNeuralEvaluator.shutdown()
	PureStateJointPolicy.shutdown()
	get_tree().quit(0 if ok and puct_ready else 1)


func _audit_unresolved_draw_target() -> bool:
	var state: Dictionary = PureStateSelfPlaySuite.basic_state(2, 1, 3, MAX_TURNS, "", false)
	var rollout := {
		"valid": true,
		"status": "turn_limit",
		"winner": "",
		"termination_reason": "turn_limit",
		"turns_played": 1,
		"max_non_progress_streak": 1,
		"history": [{"state_before": state.duplicate(true)}],
		"final_state": state.duplicate(true),
	}
	var built: Dictionary = PureStateTrainingData.build_examples_from_rollout(
		rollout, "terran", "zerg", "draw-target-audit",
		{"dataset": "basic_random_self_play", "reward_discount": 0.95}
	)
	if not bool(built.get("labeled", false)):
		push_error("basic_random_self_play unresolved rollout was not labeled")
		return false
	var examples: Array = built.get("examples", []) as Array
	if examples.is_empty():
		push_error("unresolved draw audit produced no examples")
		return false
	for example_variant in examples:
		if not (example_variant is Dictionary):
			push_error("unresolved draw audit produced invalid example")
			return false
		var example: Dictionary = example_variant
		if not is_zero_approx(float(example.get("outcome", 1.0))):
			push_error("unresolved draw audit produced non-zero target")
			return false
		if bool(example.get("terminal", true)):
			push_error("turn-limit draw target must not masquerade as a terminal state")
			return false
	return true


func _same_puct_decision(a: Dictionary, b: Dictionary) -> bool:
	if not bool(a.get("valid", false)) or not bool(b.get("valid", false)):
		return false
	if a.get("actions", []) != b.get("actions", []):
		return false
	var ad: Dictionary = a.get("diagnostics", {})
	var bd: Dictionary = b.get("diagnostics", {})
	return _stable_puct_edges(ad.get("own_edge_stats", [])) == _stable_puct_edges(bd.get("own_edge_stats", [])) and _stable_puct_edges(ad.get("opponent_edge_stats", [])) == _stable_puct_edges(bd.get("opponent_edge_stats", []))


func _stable_puct_edges(edges_variant: Variant) -> Array:
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


func _puct_visit_accounting_ok(decision: Dictionary, expected: int) -> bool:
	if not bool(decision.get("valid", false)):
		return false
	var diagnostics: Dictionary = decision.get("diagnostics", {})
	if str(diagnostics.get("search_type", "")) != "simultaneous_puct_root":
		return false
	if not bool(diagnostics.get("simultaneous_pre_turn", false)):
		return false
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
		"own_edge_stats": _stable_puct_edges(diagnostics.get("own_edge_stats", [])),
		"opponent_edge_stats": _stable_puct_edges(diagnostics.get("opponent_edge_stats", [])),
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


func _summarize_search_matrix(row: Dictionary) -> Dictionary:
	if not bool(row.get("valid", false)):
		return {"valid": false, "error": str(row.get("error", ""))}
	var candidates: Array = row.get("candidates", []) as Array
	var split_count: int = 0
	var best_score: float = -INF
	var best_split_score: float = -INF
	var best_actions: Array = []
	var best_split_actions: Array = []
	for candidate_variant in candidates:
		if not (candidate_variant is Dictionary):
			continue
		var candidate: Dictionary = candidate_variant
		var actions: Array = candidate.get("actions", []) as Array
		var score: float = float(candidate.get("handwritten_worst_case_score", -INF))
		if score > best_score:
			best_score = score
			best_actions = actions.duplicate(true)
		if _is_split_fire(actions):
			split_count += 1
			if score > best_split_score:
				best_split_score = score
				best_split_actions = actions.duplicate(true)
	return {
		"valid": true,
		"candidate_count": candidates.size(),
		"split_fire_count": split_count,
		"split_fire_present": split_count > 0,
		"best_handwritten_worst_case_score": best_score,
		"best_actions": best_actions,
		"best_split_handwritten_worst_case_score": best_split_score if split_count > 0 else null,
		"best_split_actions": best_split_actions,
	}


func _summarize_neural_plans(plans: Array) -> Dictionary:
	var split_count: int = 0
	var first_split_rank: int = -1
	var first_split_actions: Array = []
	var first_split_score = null
	for index in range(plans.size()):
		var plan_variant = plans[index]
		if not (plan_variant is Dictionary):
			continue
		var plan: Dictionary = plan_variant
		var actions: Array = plan.get("actions", []) as Array
		if _is_split_fire(actions):
			split_count += 1
			if first_split_rank < 0:
				first_split_rank = index + 1
				first_split_actions = actions.duplicate(true)
				first_split_score = float(plan.get("proposal_score", 0.0))
	return {
		"plan_count": plans.size(),
		"split_fire_count": split_count,
		"split_fire_present": split_count > 0,
		"first_split_rank": first_split_rank,
		"first_split_proposal_score": first_split_score,
		"first_split_actions": first_split_actions,
		"top_plan": (plans[0] as Dictionary).duplicate(true) if not plans.is_empty() and plans[0] is Dictionary else {},
	}


func _is_split_fire(actions: Array) -> bool:
	var attack_count: int = 0
	var cells: Dictionary = {}
	for action_variant in actions:
		if not (action_variant is Dictionary):
			continue
		var action: Dictionary = action_variant
		var key: String = str(action.get("action_key", ""))
		if not key.begins_with("attack"):
			continue
		attack_count += 1
		cells[_cell_signature(action.get("end_point", []))] = true
	return attack_count >= 2 and cells.size() >= 2


func _cell_signature(cell_variant: Variant) -> String:
	if cell_variant is Vector2i:
		var cell_i: Vector2i = cell_variant
		return "%d,%d" % [cell_i.x, cell_i.y]
	if cell_variant is Vector2:
		var cell_f: Vector2 = cell_variant
		return "%d,%d" % [int(cell_f.x), int(cell_f.y)]
	if cell_variant is Array and (cell_variant as Array).size() >= 2:
		var cell_array: Array = cell_variant
		return "%d,%d" % [int(cell_array[0]), int(cell_array[1])]
	return str(cell_variant)


func _write_json(path: String, value: Variant) -> bool:
	var absolute: String = path if path.is_absolute_path() else ProjectSettings.globalize_path(path)
	var dir_path: String = absolute.get_base_dir()
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
	var raw: PackedStringArray = OS.get_cmdline_user_args()
	if raw.is_empty():
		raw = OS.get_cmdline_args()
	for raw_variant in raw:
		var arg: String = str(raw_variant).strip_edges()
		if arg.begins_with("--"):
			arg = arg.substr(2)
		if not arg.contains("="):
			continue
		var parts: PackedStringArray = arg.split("=", true, 1)
		if parts.size() == 2:
			result[parts[0]] = parts[1]
	return result
