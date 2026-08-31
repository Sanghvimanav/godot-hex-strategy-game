extends RefCounted
## Regression test: opponent modeling should turn the old one-hex evade into a real retreat.

const PureStateOpponentResponseSearch = preload("res://src/simulation/pure_state_opponent_response_search.gd")
const PureStateOneTurnSearch = preload("res://src/simulation/pure_state_one_turn_search.gd")
const TurnExecutionCore = preload("res://src/battle/turn_execution_core.gd")
const TestOpponentResponseMarineSpread = preload("res://tests/test_opponent_response_marine_spread.gd")


static func run_all(tests: Node) -> bool:
	var ok := _test_retreat_drill_prefers_robust_distance(tests)
	ok = TestOpponentResponseMarineSpread.run_all(tests) and ok
	return ok


static func _test_retreat_drill_prefers_robust_distance(tests: Node) -> bool:
	tests._log("test_opponent_response_retreat: existing 1-Zergling vs 3-Marines retreat drill")
	var state := _pure_state_from_scenario("eval_phase_zergling_retreat_vs_3marines")
	if state.is_empty():
		tests._fail("expected retreat scenario to exist")
		return false

	# Reproduce the old one-turn assumption: every Marine is known to shoot the
	# Zergling's starting cell. Under that fixed plan, [-3,1] is a cheap one-hex
	# dodge and ties the farther retreat cells on post-turn material value.
	var fixed_marine_actions: Array = []
	for unit_id in [1, 2, 3]:
		fixed_marine_actions.append({
			"unit_id": unit_id,
			"action_key": "attack_short",
			"path": [],
			"end_point": [-3, 2],
		})
	var one_turn := PureStateOneTurnSearch.search(
		state,
		"zerg",
		{"terran": fixed_marine_actions},
		10,
		20
	)
	if not bool(one_turn.get("valid", false)):
		tests._fail("comparison one-turn search should be valid")
		return false
	var old_evade := _single_target(one_turn.get("best_actions", []))
	if old_evade != Vector2i(-3, 1):
		tests._fail("regression setup expects old fixed-response search to evade to [-3,1], got %s" % old_evade)
		return false

	# Now let the three Marines generate their own plausible joint plans. A genuine
	# retreat should survive more of those simultaneous responses than the adjacent
	# [-3,1] dodge.
	var robust := PureStateOpponentResponseSearch.search(
		state,
		"zerg",
		"terran",
		10,
		20,
		10,
		40
	)
	if not bool(robust.get("valid", false)):
		tests._fail("opponent-response retreat search should be valid")
		return false
	_print_top_results(tests, robust, 8)
	_print_runtime(tests, robust)

	var robust_target := _single_target(robust.get("best_actions", []))
	var stated_retreat_targets := [Vector2i(-4, 3), Vector2i(-4, 2), Vector2i(-3, 3)]
	if robust_target not in stated_retreat_targets:
		tests._fail("opponent modeling should choose one of the scenario's farther retreat cells, got %s" % robust_target)
		return false

	var old_evade_result := _find_fast_move_result(robust.get("ranked_results", []), Vector2i(-3, 1))
	if old_evade_result.is_empty():
		tests._fail("robust ranking should retain the old [-3,1] evade for comparison")
		return false
	var robust_worst := float(robust.get("best_worst_case_score", 0.0))
	var old_evade_worst := float(old_evade_result.get("worst_case_score", 0.0))
	if robust_worst <= old_evade_worst or is_equal_approx(robust_worst, old_evade_worst):
		tests._fail("farther retreat should have a strictly better worst case than old evade: retreat=%.2f evade=%.2f" % [robust_worst, old_evade_worst])
		return false

	var breakdown: Dictionary = robust.get("best_worst_evaluation_breakdown", {})
	if int(breakdown.get("friendly_units", 0)) != 1:
		tests._fail("robust retreat should keep the Zergling alive under its worst generated response: %s" % breakdown)
		return false

	tests._log("  old fixed-response search: fast_move -> %s" % old_evade)
	tests._log("  opponent-response search: fast_move -> %s; worst %.2f vs old evade %.2f" % [
		robust_target,
		robust_worst,
		old_evade_worst,
	])
	tests._pass("opponent modeling upgrades the one-hex evade into a farther robust retreat")
	return true


static func _find_fast_move_result(ranked: Array, target: Vector2i) -> Dictionary:
	for item_variant in ranked:
		if not (item_variant is Dictionary):
			continue
		var item: Dictionary = item_variant
		var actions: Array = item.get("actions", [])
		if actions.size() != 1 or not (actions[0] is Dictionary):
			continue
		var action: Dictionary = actions[0]
		if str(action.get("action_key", "")) == "fast_move" and _cell_from_variant(action.get("end_point", [])) == target:
			return item
	return {}


static func _print_top_results(tests: Node, result: Dictionary, limit: int) -> void:
	var ranked: Array = result.get("ranked_results", [])
	tests._log("  retreat robust results:")
	for i in range(mini(limit, ranked.size())):
		var item: Dictionary = ranked[i]
		tests._log("    #%d worst=%.2f avg=%.2f proposal=%.2f %s | worst response: %s" % [
			i + 1,
			float(item.get("worst_case_score", 0.0)),
			float(item.get("average_score", 0.0)),
			float(item.get("proposal_score", 0.0)),
			_plan_summary(item.get("actions", [])),
			_plan_summary(item.get("worst_response_actions", [])),
		])


static func _print_runtime(tests: Node, result: Dictionary) -> void:
	var elapsed_ms := float(result.get("elapsed_ms", 0.0))
	var simulations := int(result.get("simulations_run", 0))
	var sims_per_second := 0.0
	if elapsed_ms > 0.0:
		sims_per_second = float(simulations) * 1000.0 / elapsed_ms
	tests._log("  runtime retreat 20x40: %d simulations in %.1f ms (%.1f sims/sec), pruned=%d" % [
		simulations,
		elapsed_ms,
		sims_per_second,
		int(result.get("pruned_candidates", 0)),
	])


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


static func _single_target(actions: Array) -> Vector2i:
	if actions.size() != 1 or not (actions[0] is Dictionary):
		return Vector2i(999, 999)
	return _cell_from_variant((actions[0] as Dictionary).get("end_point", []))


static func _plan_summary(actions: Array) -> String:
	var parts: PackedStringArray = []
	for action_variant in actions:
		if not (action_variant is Dictionary):
			continue
		var action: Dictionary = action_variant
		parts.append("U%d %s -> %s" % [
			int(action.get("unit_id", -1)),
			str(action.get("action_key", "")),
			str(action.get("end_point", [])),
		])
	return "; ".join(parts)


static func _cell_from_variant(value: Variant) -> Vector2i:
	if value is Vector2i:
		return value
	if value is Vector2:
		return Vector2i(int(value.x), int(value.y))
	if value is Array and value.size() >= 2:
		return Vector2i(int(value[0]), int(value[1]))
	return Vector2i.ZERO
