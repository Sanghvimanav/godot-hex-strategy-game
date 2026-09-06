extends RefCounted
## Contract and parity tests for the canonical gameplay AI entry point.

const GameplayAI = preload("res://src/battle/ai/gameplay_ai.gd")
const PureStateOpponentResponseSearch = preload("res://src/simulation/pure_state_opponent_response_search.gd")
const PureStatePolicyExploration = preload("res://src/simulation/pure_state_policy_exploration.gd")
const TurnExecutionCore = preload("res://src/battle/turn_execution_core.gd")


static func run_all(tests: Node) -> bool:
	var ok := true
	ok = _test_handwritten_entry_point_matches_existing_search(tests) and ok
	ok = _test_policy_exploration_is_seeded_and_near_best_only(tests) and ok
	ok = _test_neural_evaluator_requires_explicit_checkpoint(tests) and ok
	ok = _test_unsupported_evaluator_fails_closed(tests) and ok
	ok = _test_unsupported_exploration_profile_fails_closed(tests) and ok
	return ok


static func _test_handwritten_entry_point_matches_existing_search(tests: Node) -> bool:
	tests._log("test_gameplay_ai: canonical entry point preserves handwritten search behavior")
	var state := _one_hp_zergling_vs_marine_state()
	var before := state.duplicate(true)
	var settings := GameplayAI.handwritten_settings(8, 4, 8, 4)
	var direct := PureStateOpponentResponseSearch.search(state, "zerg", "terran", 8, 4, 8, 4)
	var decision := GameplayAI.choose_actions(state, "zerg", "terran", settings)

	if not bool(direct.get("valid", false)) or not bool(decision.get("valid", false)):
		tests._fail("direct search and gameplay entry point should both return valid decisions")
		return false
	if state != before:
		tests._fail("gameplay AI must not mutate its source state")
		return false
	if decision.get("actions", []) != direct.get("best_actions", []):
		tests._fail("entry point must preserve the current handwritten action choice")
		return false
	if str(decision.get("policy", "")) != GameplayAI.POLICY_OPPONENT_RESPONSE:
		tests._fail("decision should identify the selected policy")
		return false
	if str(decision.get("evaluator", "")) != GameplayAI.EVALUATOR_HANDWRITTEN:
		tests._fail("decision should identify the selected evaluator")
		return false
	var diagnostics: Dictionary = decision.get("diagnostics", {})
	if diagnostics.get("best_actions", []) != decision.get("actions", []):
		tests._fail("greedy default must preserve the search winner exactly")
		return false
	if diagnostics.get("selected_actions", []) != decision.get("actions", []):
		tests._fail("diagnostics should expose the final selected actions")
		return false
	if str(diagnostics.get("evaluator", "")) != GameplayAI.EVALUATOR_HANDWRITTEN:
		tests._fail("search diagnostics should identify the leaf evaluator")
		return false
	var exploration: Dictionary = diagnostics.get("exploration", {})
	if bool(exploration.get("explored", true)) or int(exploration.get("selected_rank", -1)) != 0:
		tests._fail("default gameplay settings must remain rank-0 deterministic")
		return false
	if int(diagnostics.get("simulations_run", 0)) <= 0:
		tests._fail("entry point should preserve runtime/search diagnostics")
		return false

	tests._pass("one entry point preserves current actions and diagnostics")
	return true


static func _test_policy_exploration_is_seeded_and_near_best_only(tests: Node) -> bool:
	tests._log("test_gameplay_ai: exploration is deterministic and never samples far-below-best plans")
	var state := _one_hp_zergling_vs_marine_state()
	var fake_search := {
		"ranked_results": [
			{"actions": [{"unit_id": 1, "action_key": "best"}], "worst_case_score": 100.0, "average_score": 105.0, "proposal_score": 10.0, "intent": "commit"},
			{"actions": [{"unit_id": 1, "action_key": "near"}], "worst_case_score": 70.0, "average_score": 80.0, "proposal_score": 9.0, "intent": "reposition"},
			{"actions": [{"unit_id": 1, "action_key": "edge"}], "worst_case_score": 25.0, "average_score": 40.0, "proposal_score": 8.0, "intent": "hold"},
			{"actions": [{"unit_id": 1, "action_key": "bad"}], "worst_case_score": -200.0, "average_score": -150.0, "proposal_score": 7.0, "intent": "disengage"},
		],
	}
	var saw_alternative := false
	for seed in range(1, 129):
		var selected := PureStatePolicyExploration.select_result(
			fake_search,
			state,
			"zerg",
			PureStatePolicyExploration.PROFILE_LIGHT,
			seed
		)
		var again := PureStatePolicyExploration.select_result(
			fake_search,
			state,
			"zerg",
			PureStatePolicyExploration.PROFILE_LIGHT,
			seed
		)
		if selected != again:
			tests._fail("same state/profile/seed must select the same policy result")
			return false
		var rank := int(selected.get("selected_rank", -1))
		if rank < 0 or rank > 2:
			tests._fail("light exploration must stay inside the top-three near-best prefix, got rank %d" % rank)
			return false
		if float(selected.get("selected_worst_case_score", -9999.0)) < 20.0:
			tests._fail("light exploration sampled outside its 80-point worst-case margin")
			return false
		if bool(selected.get("explored", false)):
			saw_alternative = true
			if rank == 0:
				tests._fail("an exploration event must actually choose a non-best plan")
				return false
	if not saw_alternative:
		tests._fail("light exploration should produce at least one alternate plan across many deterministic seeds")
		return false
	tests._pass("exploration is reproducible and constrained to near-best plans")
	return true


static func _test_neural_evaluator_requires_explicit_checkpoint(tests: Node) -> bool:
	tests._log("test_gameplay_ai: neural evaluator is explicit and fails closed without a checkpoint")
	var state := _one_hp_zergling_vs_marine_state()
	var decision := GameplayAI.choose_actions(state, "zerg", "terran", {
		"evaluator": GameplayAI.EVALUATOR_NEURAL,
	})
	if bool(decision.get("valid", true)):
		tests._fail("neural mode without explicit evaluator settings must not silently fall back")
		return false
	if str(decision.get("error", "")) != "neural_checkpoint_required":
		tests._fail("missing neural checkpoint should return a stable explicit error")
		return false
	if not (decision.get("actions", []) as Array).is_empty():
		tests._fail("failed neural decisions must not return partial actions")
		return false
	tests._pass("neural evaluation is opt-in and fail-closed")
	return true


static func _test_unsupported_evaluator_fails_closed(tests: Node) -> bool:
	tests._log("test_gameplay_ai: unsupported evaluator fails closed")
	var state := _one_hp_zergling_vs_marine_state()
	var decision := GameplayAI.choose_actions(state, "zerg", "terran", {
		"evaluator": "oracle",
	})
	if bool(decision.get("valid", true)):
		tests._fail("an evaluator that is not integrated must not silently use another implementation")
		return false
	if str(decision.get("error", "")) != "unsupported_evaluator":
		tests._fail("unsupported evaluator should return an explicit stable error")
		return false
	if not (decision.get("actions", []) as Array).is_empty():
		tests._fail("failed decisions must not return partial actions")
		return false
	tests._pass("unknown evaluator modes remain fail-closed")
	return true


static func _test_unsupported_exploration_profile_fails_closed(tests: Node) -> bool:
	tests._log("test_gameplay_ai: unsupported exploration profile fails closed")
	var state := _one_hp_zergling_vs_marine_state()
	var decision := GameplayAI.choose_actions(state, "zerg", "terran", {
		"exploration_profile": "wild_random",
	})
	if bool(decision.get("valid", true)):
		tests._fail("unknown exploration profiles must not silently change gameplay policy")
		return false
	if str(decision.get("error", "")) != "unsupported_exploration_profile":
		tests._fail("unknown exploration profile should return a stable explicit error")
		return false
	tests._pass("exploration remains opt-in and fail-closed")
	return true


static func _one_hp_zergling_vs_marine_state() -> Dictionary:
	return {
		"scenario_id": "gameplay_ai_parity",
		"hex_radius": 5,
		"groups": [
			{"name": "zerg", "resources": {}, "units": [
				_make_unit(1, "res://src/unit/definitions/zergling.tres", Vector2i(-2, 0), 1),
			]},
			{"name": "terran", "resources": {}, "units": [
				_make_unit(2, "res://src/unit/definitions/marine.tres", Vector2i(0, 0)),
			]},
		],
		"tile_resources": {},
	}


static func _make_unit(
	unit_id: int,
	def_path: String,
	cell: Vector2i,
	health_override: int = -1
) -> Dictionary:
	var def_dict := TurnExecutionCore.get_unit_def(def_path)
	var max_health := int(def_dict.get("max_health", 2))
	var max_energy := int(def_dict.get("max_energy", 0))
	var start_energy := int(def_dict.get("start_energy", max_energy))
	return {
		"unit_id": unit_id,
		"def_path": def_path,
		"cell": [cell.x, cell.y],
		"health": max_health if health_override < 0 else health_override,
		"max_health": max_health,
		"energy": start_energy,
		"max_energy": max_energy,
		"effects": [],
		"is_active": true,
	}
