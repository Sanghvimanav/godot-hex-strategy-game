extends RefCounted
## End-to-end tests for bounded simultaneous opponent-response search.

const PureStateOpponentResponseSearch = preload("res://src/simulation/pure_state_opponent_response_search.gd")
const PureStateOneTurnSearch = preload("res://src/simulation/pure_state_one_turn_search.gd")
const TurnExecutionCore = preload("res://src/battle/turn_execution_core.gd")


static func run_all(tests: Node) -> bool:
	var ok := true
	ok = _test_search_is_bounded_deterministic_and_pure(tests) and ok
	ok = _test_response_search_avoids_predictable_shot(tests) and ok
	ok = _test_collapse_stays_winning_under_responses(tests) and ok
	ok = _test_complete_command_capture_is_terminal_in_opt_in_continuations(tests) and ok
	return ok


static func _test_complete_command_capture_is_terminal_in_opt_in_continuations(tests: Node) -> bool:
	var before := _one_hp_zergling_vs_marine_state()
	before["command_hexes"] = {"zerg": [-5, 0], "terran": [5, 0]}
	var groups: Array = before.get("groups", [])
	var zerg: Dictionary = groups[1]
	var zerg_units: Array = zerg.get("units", [])
	(zerg_units[0] as Dictionary)["cell"] = [5, 0]
	var after := before.duplicate(true)
	var enabled := {"score_command_capture": true}
	var win := PureStateOpponentResponseSearch._capture_terminal_breakdown(before, after, "zerg", "terran", enabled)
	if float(win.get("total", 0.0)) != 100000.0:
		tests._fail("one full held command turn must score an exact win")
		return false
	var disabled := PureStateOpponentResponseSearch._capture_terminal_breakdown(before, after, "zerg", "terran", {})
	if not disabled.is_empty():
		tests._fail("normal one-turn search must not change its terminal scoring")
		return false
	var terran: Dictionary = groups[0]
	var terran_units: Array = terran.get("units", [])
	(terran_units[0] as Dictionary)["cell"] = [-5, 0]
	after = before.duplicate(true)
	var draw := PureStateOpponentResponseSearch._capture_terminal_breakdown(before, after, "zerg", "terran", enabled)
	if float(draw.get("total", -1.0)) != 0.0 or str(draw.get("terminal_reason", "")) != "simultaneous_command_capture":
		tests._fail("two completed captures must score as a terminal draw")
		return false
	tests._pass("opt-in second-turn objective scoring matches win and simultaneous-draw rules")
	return true


static func _test_search_is_bounded_deterministic_and_pure(tests: Node) -> bool:
	tests._log("test_pure_state_opponent_response_search: bounded deterministic pure")
	var state := _one_hp_zergling_vs_marine_state()
	var before := state.duplicate(true)
	var first := PureStateOpponentResponseSearch.search(state, "zerg", "terran", 8, 4, 13, 4)
	var second := PureStateOpponentResponseSearch.search(state, "zerg", "terran", 8, 4, 13, 4)
	if not bool(first.get("valid", false)):
		tests._fail("expected valid opponent-response search")
		return false
	if state != before:
		tests._fail("opponent-response search must not mutate source state")
		return false
	if int(first.get("own_candidates_considered", 0)) > 4 or int(first.get("opponent_candidates_considered", 0)) > 4:
		tests._fail("search should respect own/opponent plan bounds")
		return false
	if int(first.get("simulations_run", 0)) > 16:
		tests._fail("4 x 4 bounds should require at most 16 simulations")
		return false
	if first.get("best_actions", []) != second.get("best_actions", []):
		tests._fail("identical inputs should choose identical robust actions")
		return false
	if not is_equal_approx(float(first.get("best_worst_case_score", 0.0)), float(second.get("best_worst_case_score", 0.0))):
		tests._fail("identical inputs should produce identical worst-case value")
		return false
	_print_runtime(tests, "bounded 4x4", first)
	tests._pass("opponent-response search is bounded, deterministic, and pure")
	return true


static func _test_response_search_avoids_predictable_shot(tests: Node) -> bool:
	tests._log("test_pure_state_opponent_response_search: potential opponent shots change move")
	var state := _one_hp_zergling_vs_marine_state()

	# With no opponent action supplied, one-turn search sees every surviving move as
	# materially equivalent and uses proposal score to move closer to the Marine.
	var one_turn := PureStateOneTurnSearch.search(state, "zerg", {}, 8, 8)
	if not bool(one_turn.get("valid", false)):
		tests._fail("comparison one-turn search should be valid")
		return false
	var one_turn_target := _single_target(one_turn.get("best_actions", []))
	var exposed_targets := [Vector2i(-1, 0), Vector2i(-1, 1)]
	if one_turn_target not in exposed_targets:
		tests._fail("test setup expects no-response search to choose a closer exposed hex, got %s" % one_turn_target)
		return false

	# Give the Marine all of its local actions so attacks on empty-at-planning-time
	# adjacent hexes are represented among plausible simultaneous responses.
	var robust := PureStateOpponentResponseSearch.search(state, "zerg", "terran", 8, 8, 13, 13)
	if not bool(robust.get("valid", false)):
		tests._fail("robust search should be valid")
		return false
	_print_top_results(tests, robust, 6)
	_print_runtime(tests, "1v1 8x13", robust)
	var robust_target := _single_target(robust.get("best_actions", []))
	if robust_target in exposed_targets:
		tests._fail("opponent-response search should avoid a hex the adjacent Marine can pre-target; got %s" % robust_target)
		return false
	var breakdown: Dictionary = robust.get("best_worst_evaluation_breakdown", {})
	if int(breakdown.get("friendly_units", 0)) != 1:
		tests._fail("robust choice should keep the 1-HP Zergling alive under its worst generated response: %s" % breakdown)
		return false
	if int(robust.get("opponent_candidates_considered", 0)) < 10:
		tests._fail("test should retain a broad Marine response set")
		return false
	tests._log("  no-response search chose %s; opponent-response search chose %s" % [one_turn_target, robust_target])
	tests._log("  worst generated Marine response: %s" % _plan_summary(robust.get("best_worst_response_actions", [])))
	tests._pass("potential opponent attacks change the selected move toward robust survival")
	return true


static func _test_collapse_stays_winning_under_responses(tests: Node) -> bool:
	tests._log("test_pure_state_opponent_response_search: collapse remains robust win")
	var state := _pure_state_from_scenario("eval_phase_4zerglings_collapse_3marines")
	var result := PureStateOpponentResponseSearch.search(state, "zerg", "terran", 8, 12, 5, 4)
	if not bool(result.get("valid", false)):
		tests._fail("collapse opponent-response search should be valid")
		return false
	_print_top_results(tests, result, 5)
	_print_runtime(tests, "collapse 12x4", result)
	var best_actions: Array = result.get("best_actions", [])
	if best_actions.size() != 4:
		tests._fail("collapse robust plan should contain four Zergling actions")
		return false
	for action_variant in best_actions:
		if not (action_variant is Dictionary):
			tests._fail("collapse action should be dictionary")
			return false
		var action: Dictionary = action_variant
		if str(action.get("action_key", "")) != "fast_move" or _cell_from_variant(action.get("end_point", [])) != Vector2i(-2, 1):
			tests._fail("expected all four Zerglings to collapse onto [-2,1], got %s" % best_actions)
			return false
	var breakdown: Dictionary = result.get("best_worst_evaluation_breakdown", {})
	if float(breakdown.get("terminal", 0.0)) <= 0.0:
		tests._fail("collapse should remain a terminal Zerg win even against worst generated Marine response: %s" % breakdown)
		return false
	tests._pass("opponent-response search keeps the immediate winning collapse")
	return true


static func _print_top_results(tests: Node, result: Dictionary, limit: int) -> void:
	var ranked: Array = result.get("ranked_results", [])
	tests._log("  top robust results:")
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


static func _print_runtime(tests: Node, label: String, result: Dictionary) -> void:
	var elapsed_ms := float(result.get("elapsed_ms", 0.0))
	var simulations := int(result.get("simulations_run", 0))
	var sims_per_second := 0.0
	if elapsed_ms > 0.0:
		sims_per_second = float(simulations) * 1000.0 / elapsed_ms
	tests._log("  runtime %s: %d simulations in %.1f ms (%.1f sims/sec), own=%d opponent=%d" % [
		label,
		simulations,
		elapsed_ms,
		sims_per_second,
		int(result.get("own_candidates_considered", 0)),
		int(result.get("opponent_candidates_considered", 0)),
	])


static func _one_hp_zergling_vs_marine_state() -> Dictionary:
	var marine := _make_unit(1, "res://src/unit/definitions/marine.tres", Vector2i(0, 0))
	var zergling := _make_unit(2, "res://src/unit/definitions/zergling.tres", Vector2i(-2, 1))
	zergling["health"] = 1
	return {
		"scenario_id": "test_opponent_response_predictive_shot",
		"hex_radius": 5,
		"groups": [
			{"name": "terran", "resources": {}, "units": [marine]},
			{"name": "zerg", "resources": {}, "units": [zergling]},
		],
		"tile_resources": {},
	}


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
