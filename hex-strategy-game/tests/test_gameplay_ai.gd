extends RefCounted
## Contract and parity tests for the canonical gameplay AI entry point.

const GameplayAI = preload("res://src/battle/ai/gameplay_ai.gd")
const PureStateOpponentResponseSearch = preload("res://src/simulation/pure_state_opponent_response_search.gd")
const TurnExecutionCore = preload("res://src/battle/turn_execution_core.gd")


static func run_all(tests: Node) -> bool:
	var ok := true
	ok = _test_handwritten_entry_point_matches_existing_search(tests) and ok
	ok = _test_unsupported_evaluator_fails_closed(tests) and ok
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
		tests._fail("search-specific diagnostics should remain available without defining the public contract")
		return false
	if int(diagnostics.get("simulations_run", 0)) <= 0:
		tests._fail("entry point should preserve runtime/search diagnostics")
		return false

	tests._pass("one entry point preserves current actions and diagnostics")
	return true


static func _test_unsupported_evaluator_fails_closed(tests: Node) -> bool:
	tests._log("test_gameplay_ai: unsupported evaluator fails closed")
	var state := _one_hp_zergling_vs_marine_state()
	var decision := GameplayAI.choose_actions(state, "zerg", "terran", {
		"evaluator": "neural",
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
	tests._pass("future evaluator modes require explicit integration")
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
