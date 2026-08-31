extends RefCounted
## End-to-end tests for candidate generation -> simulation -> evaluation -> selection.

const PureStateOneTurnSearch = preload("res://src/simulation/pure_state_one_turn_search.gd")
const TurnExecutionCore = preload("res://src/battle/turn_execution_core.gd")


static func run_all(tests: Node) -> bool:
	var ok := true
	ok = _test_search_is_bounded_deterministic_and_pure(tests) and ok
	ok = _test_collapse_scenario_selects_winning_joint_plan(tests) and ok
	ok = _test_retreat_scenario_evaluation_overrides_proposal_bias(tests) and ok
	return ok


static func _test_search_is_bounded_deterministic_and_pure(tests: Node) -> bool:
	tests._log("test_pure_state_one_turn_search: bounded deterministic pure search")
	var state := _pure_state_from_scenario("eval_phase_4zerglings_collapse_3marines")
	var before := state.duplicate(true)
	var first := PureStateOneTurnSearch.search(state, "zerg", {}, 4, 12)
	var second := PureStateOneTurnSearch.search(state, "zerg", {}, 4, 12)
	if not bool(first.get("valid", false)):
		tests._fail("expected valid search result")
		return false
	if int(first.get("candidates_considered", 0)) > 12:
		tests._fail("search should respect max_plans=12")
		return false
	if state != before:
		tests._fail("search must not mutate source state")
		return false
	if first.get("best_actions", []) != second.get("best_actions", []):
		tests._fail("identical search inputs should choose identical actions")
		return false
	if not is_equal_approx(float(first.get("best_evaluation_score", 0.0)), float(second.get("best_evaluation_score", 0.0))):
		tests._fail("identical search inputs should produce identical evaluation")
		return false
	tests._pass("one-turn search is bounded, deterministic, and pure")
	return true


static func _test_collapse_scenario_selects_winning_joint_plan(tests: Node) -> bool:
	tests._log("test_pure_state_one_turn_search: 4-Zergling collapse")
	var state := _pure_state_from_scenario("eval_phase_4zerglings_collapse_3marines")
	var result := PureStateOneTurnSearch.search(state, "zerg", {}, 8, 50)
	if not bool(result.get("valid", false)):
		tests._fail("collapse scenario search should be valid")
		return false
	_print_top_results(tests, result, 5)
	var best_actions: Array = result.get("best_actions", [])
	if best_actions.size() != 4:
		tests._fail("collapse best plan should contain four Zergling actions")
		return false
	for action_variant in best_actions:
		if not (action_variant is Dictionary):
			tests._fail("best action should be dictionary")
			return false
		var action: Dictionary = action_variant
		if str(action.get("action_key", "")) != "fast_move" or _cell_from_variant(action.get("end_point", [])) != Vector2i(-2, 1):
			tests._fail("expected every Zergling to fast_move onto [-2,1], got %s" % best_actions)
			return false
	var breakdown: Dictionary = result.get("best_evaluation_breakdown", {})
	if float(breakdown.get("terminal", 0.0)) <= 0.0:
		tests._fail("selected collapse should be a terminal Zerg win: %s" % breakdown)
		return false
	tests._log("  selected collapse proposal=%.2f eval=%.2f" % [
		float(result.get("best_proposal_score", 0.0)),
		float(result.get("best_evaluation_score", 0.0)),
	])
	tests._pass("one-turn search selects the coordinated winning collapse")
	return true


static func _test_retreat_scenario_evaluation_overrides_proposal_bias(tests: Node) -> bool:
	tests._log("test_pure_state_one_turn_search: evasive move overrides proposal bias")
	var state := _pure_state_from_scenario("eval_phase_zergling_retreat_vs_3marines")
	var marine_actions: Array = []
	for unit_id in [1, 2, 3]:
		marine_actions.append({
			"unit_id": unit_id,
			"action_key": "attack_short",
			"path": [],
			"end_point": [-3, 2],
		})
	var result := PureStateOneTurnSearch.search(state, "zerg", {"terran": marine_actions}, 10, 20)
	if not bool(result.get("valid", false)):
		tests._fail("retreat scenario search should be valid")
		return false
	_print_top_results(tests, result, 8)
	var best_actions: Array = result.get("best_actions", [])
	if best_actions.size() != 1 or not (best_actions[0] is Dictionary):
		tests._fail("retreat scenario best plan should contain one Zergling action")
		return false
	var best_action: Dictionary = best_actions[0]
	var best_target := _cell_from_variant(best_action.get("end_point", []))
	if str(best_action.get("action_key", "")) != "fast_move" or best_target == Vector2i(-3, 2):
		tests._fail("search should choose an evasive move away from the targeted old tile, got %s" % best_action)
		return false

	var ranked: Array = result.get("ranked_results", [])
	var stay_result: Dictionary = {}
	var stated_retreat_result: Dictionary = {}
	var stated_retreat_targets := [Vector2i(-4, 3), Vector2i(-4, 2), Vector2i(-3, 3)]
	for ranked_variant in ranked:
		if not (ranked_variant is Dictionary):
			continue
		var item: Dictionary = ranked_variant
		var actions: Array = item.get("actions", [])
		if actions.size() != 1 or not (actions[0] is Dictionary):
			continue
		var action: Dictionary = actions[0]
		var action_key := str(action.get("action_key", ""))
		var target := _cell_from_variant(action.get("end_point", []))
		if stay_result.is_empty() and action_key == "reload":
			stay_result = item
		if stated_retreat_result.is_empty() and action_key == "fast_move" and target in stated_retreat_targets:
			stated_retreat_result = item
	if stay_result.is_empty():
		tests._fail("ranked search results should retain reload/stay for comparison")
		return false
	if stated_retreat_result.is_empty():
		tests._fail("ranked search results should retain at least one scenario-stated farther retreat")
		return false
	if float(stay_result.get("proposal_score", 0.0)) <= float(result.get("best_proposal_score", 0.0)):
		tests._fail("test expects cheap proposal heuristic to prefer stay over the selected evasive move")
		return false
	if float(stay_result.get("evaluation_score", 0.0)) >= float(result.get("best_evaluation_score", 0.0)):
		tests._fail("post-simulation evaluation should override proposal bias toward staying")
		return false
	if not is_equal_approx(float(stated_retreat_result.get("evaluation_score", 0.0)), float(result.get("best_evaluation_score", 0.0))):
		tests._fail("farther stated retreat should tie the selected evasive move at a one-turn horizon")
		return false
	var best_breakdown: Dictionary = result.get("best_evaluation_breakdown", {})
	if int(best_breakdown.get("friendly_units", 0)) != 1:
		tests._fail("selected evasive move should leave the Zergling alive: %s" % best_breakdown)
		return false
	tests._log("  proposal preferred stay %.2f > selected %.2f; evaluation chose survival %.2f > stay %.2f" % [
		float(stay_result.get("proposal_score", 0.0)),
		float(result.get("best_proposal_score", 0.0)),
		float(result.get("best_evaluation_score", 0.0)),
		float(stay_result.get("evaluation_score", 0.0)),
	])
	tests._log("  farther scenario retreat ties at eval=%.2f; one-turn search uses proposal score only as tie-breaker" % float(stated_retreat_result.get("evaluation_score", 0.0)))
	tests._pass("one-turn search chooses survival over heuristic-preferred stay without overclaiming next-turn safety")
	return true


static func _print_top_results(tests: Node, result: Dictionary, limit: int) -> void:
	var ranked: Array = result.get("ranked_results", [])
	tests._log("  top search results:")
	for i in range(mini(limit, ranked.size())):
		var item: Dictionary = ranked[i]
		tests._log("    #%d eval=%.2f proposal=%.2f %s" % [
			i + 1,
			float(item.get("evaluation_score", 0.0)),
			float(item.get("proposal_score", 0.0)),
			_plan_summary(item.get("actions", [])),
		])


static func _plan_summary(actions: Array) -> String:
	var parts: PackedStringArray = []
	for action_variant in actions:
		if action_variant is Dictionary:
			var action: Dictionary = action_variant
			parts.append("U%d %s -> %s" % [
				int(action.get("unit_id", -1)),
				str(action.get("action_key", "")),
				str(action.get("end_point", [])),
			])
	return "; ".join(parts)


static func _pure_state_from_scenario(scenario_id: String) -> Dictionary:
	var scenario: Dictionary = Scenarios.get_scenario_by_id(scenario_id)
	if scenario.is_empty():
		return {}
	var groups: Array = []
	var next_unit_id := 1
	for group_variant in scenario.get("groups", []):
		if not (group_variant is Dictionary):
			continue
		var source_group: Dictionary = group_variant
		var units: Array = []
		for spec_variant in source_group.get("units", []):
			if not (spec_variant is Dictionary):
				continue
			var spec: Dictionary = spec_variant
			var def_path := str(spec.get("def_path", ""))
			var cell := _cell_from_variant(spec.get("cell", Vector2i.ZERO))
			var unit := _make_unit(next_unit_id, def_path, cell)
			if spec.has("health"):
				unit["health"] = int(spec.get("health", unit.get("health", 2)))
			if spec.has("energy"):
				unit["energy"] = int(spec.get("energy", unit.get("energy", 0)))
			units.append(unit)
			next_unit_id += 1
		groups.append({
			"name": str(source_group.get("name", "")),
			"ai": bool(source_group.get("ai", false)),
			"resources": source_group.get("resources", {}).duplicate(true),
			"units": units,
		})
	return {
		"scenario_id": scenario_id,
		"hex_radius": 5,
		"groups": groups,
		"tile_resources": scenario.get("tile_resources", {}).duplicate(true),
	}


static func _make_unit(unit_id: int, def_path: String, cell: Vector2i) -> Dictionary:
	var def_dict := TurnExecutionCore.get_unit_def(def_path)
	var max_health := int(def_dict.get("max_health", 2))
	var max_energy := int(def_dict.get("max_energy", 0))
	var start_energy := int(def_dict.get("start_energy", max_energy))
	return {
		"unit_id": unit_id,
		"def_path": def_path,
		"cell": [cell.x, cell.y],
		"health": max_health,
		"max_health": max_health,
		"energy": start_energy,
		"max_energy": max_energy,
		"effects": [],
		"is_active": true,
	}


static func _cell_from_variant(value: Variant) -> Vector2i:
	if value is Vector2i:
		return value
	if value is Vector2:
		return Vector2i(int(value.x), int(value.y))
	if value is Array and value.size() >= 2:
		return Vector2i(int(value[0]), int(value[1]))
	return Vector2i.ZERO
