extends RefCounted
## Regression coverage for opponent-conditioned own-plan proposal injection.

const PureStateOneTurnSearch = preload("res://src/simulation/pure_state_one_turn_search.gd")
const PureStateOpponentResponseSearch = preload("res://src/simulation/pure_state_opponent_response_search.gd")
const TurnExecutionCore = preload("res://src/battle/turn_execution_core.gd")


static func run_all(tests: Node) -> bool:
	return _test_scout_predictive_shot_is_injected_from_modeled_zergling_move(tests)


static func _test_scout_predictive_shot_is_injected_from_modeled_zergling_move(tests: Node) -> bool:
	const SCENARIO_ID := "eval_scout_prioritize_zergling_over_mountain"
	const PREDICTED_CELL := Vector2i(3, -3)
	tests._log("test_opponent_conditioned_counters: Scout can counter modeled Zergling destination")
	var state := _pure_state_from_scenario(SCENARIO_ID)
	if state.is_empty():
		tests._fail("missing scenario %s" % SCENARIO_ID)
		return false

	# Preserve the old diagnostic: one-turn generation against a scripted move did
	# not retain the empty-at-planning-time predictive shot.
	var zergling_id := _find_unit_id_by_def(state, "zerg", "zergling.tres")
	if zergling_id < 0:
		tests._fail("scenario should contain Zergling")
		return false
	var scripted_zerg := [{
		"unit_id": zergling_id,
		"action_key": "fast_move",
		"path": [[PREDICTED_CELL.x, PREDICTED_CELL.y]],
		"end_point": [PREDICTED_CELL.x, PREDICTED_CELL.y],
	}]
	var baseline := PureStateOneTurnSearch.search(state, "terran", {"zerg": scripted_zerg})
	var baseline_present := _result_has_action(baseline, "attack_ray", PREDICTED_CELL)

	# Opponent-response search first models Zerg movement, then feeds modeled move
	# destinations back into Terran proposal generation. The predictive shot must
	# now reach the simulation set even though [3,-3] is empty in the source state.
	var robust := PureStateOpponentResponseSearch.search(state, "terran", "zerg", 8, 20, 8, 8)
	if not bool(robust.get("valid", false)):
		tests._fail("opponent-conditioned search should be valid")
		return false
	var condition_cells: Array = robust.get("counter_condition_cells", [])
	if not _cells_contain(condition_cells, PREDICTED_CELL):
		tests._fail("modeled opponent moves should include Zergling destination [3,-3], got %s" % condition_cells)
		return false
	if int(robust.get("counter_injected_source_candidates", 0)) <= 0:
		tests._fail("opponent destinations should inject at least one counter proposal")
		return false
	if not _result_has_action(robust, "attack_ray", PREDICTED_CELL):
		tests._fail("Scout attack_ray -> [3,-3] should survive into robust ranked results")
		return false

	var selected := _actions_have_action(robust.get("best_actions", []), "attack_ray", PREDICTED_CELL)
	var predictive := _find_result_with_action(robust, "attack_ray", PREDICTED_CELL)
	tests._log("  baseline predictive candidate present=%s" % str(baseline_present))
	tests._log("  conditioned cells=%s; injected=%d" % [
		str(condition_cells),
		int(robust.get("counter_injected_source_candidates", 0)),
	])
	tests._log("  predictive candidate worst=%.2f avg=%.2f selected=%s; best=%s" % [
		float(predictive.get("worst_case_score", 0.0)),
		float(predictive.get("average_score", 0.0)),
		str(selected),
		_plan_summary(robust.get("best_actions", [])),
	])
	tests._pass("modeled Zergling movement injects the Scout predictive shot before minimax evaluation")
	return true


static func _result_has_action(result: Dictionary, action_key: String, target: Vector2i) -> bool:
	for item_variant in result.get("ranked_results", []):
		if not (item_variant is Dictionary):
			continue
		if _actions_have_action((item_variant as Dictionary).get("actions", []), action_key, target):
			return true
	return false


static func _find_result_with_action(result: Dictionary, action_key: String, target: Vector2i) -> Dictionary:
	for item_variant in result.get("ranked_results", []):
		if item_variant is Dictionary and _actions_have_action((item_variant as Dictionary).get("actions", []), action_key, target):
			return (item_variant as Dictionary).duplicate(true)
	return {}


static func _actions_have_action(actions: Array, action_key: String, target: Vector2i) -> bool:
	for action_variant in actions:
		if not (action_variant is Dictionary):
			continue
		var action: Dictionary = action_variant
		if str(action.get("action_key", "")) == action_key and _cell_from_variant(action.get("end_point", [])) == target:
			return true
	return false


static func _cells_contain(cells: Array, target: Vector2i) -> bool:
	for value in cells:
		if _cell_from_variant(value) == target:
			return true
	return false


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


static func _find_unit_id_by_def(state: Dictionary, group_name: String, filename: String) -> int:
	for group_variant in state.get("groups", []):
		if not (group_variant is Dictionary):
			continue
		var group: Dictionary = group_variant
		if str(group.get("name", "")) != group_name:
			continue
		for unit_variant in group.get("units", []):
			if unit_variant is Dictionary and str((unit_variant as Dictionary).get("def_path", "")).ends_with(filename):
				return int((unit_variant as Dictionary).get("unit_id", -1))
	return -1


static func _plan_summary(actions: Array) -> String:
	var parts: PackedStringArray = []
	for action_variant in actions:
		if action_variant is Dictionary:
			parts.append("U%d %s -> %s" % [
				int((action_variant as Dictionary).get("unit_id", -1)),
				str((action_variant as Dictionary).get("action_key", "")),
				str((action_variant as Dictionary).get("end_point", [])),
			])
	return "; ".join(parts)


static func _cell_from_variant(value: Variant) -> Vector2i:
	if value is Vector2i:
		return value
	if value is Vector2:
		return Vector2i(int(value.x), int(value.y))
	if value is Array and value.size() >= 2:
		return Vector2i(int(value[0]), int(value[1]))
	return Vector2i(999999, 999999)
