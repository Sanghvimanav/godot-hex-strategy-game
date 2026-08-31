extends RefCounted
## End-to-end regression: multiple Marines should spread predictive fire across
## plausible simultaneous Zergling destinations instead of stacking every shot
## on the Zergling's planning-time cell.

const PureStateOpponentResponseSearch = preload("res://src/simulation/pure_state_opponent_response_search.gd")
const PureStatePlans = preload("res://src/simulation/pure_state_plans.gd")
const TurnExecutionCore = preload("res://src/battle/turn_execution_core.gd")


static func run_all(tests: Node) -> bool:
	return _test_marines_spread_two_tile_fire_across_likely_zergling_moves(tests)


static func _test_marines_spread_two_tile_fire_across_likely_zergling_moves(tests: Node) -> bool:
	tests._log("test_opponent_response_marine_spread: Marines spread predictive two-tile fire")
	var state := _spread_fire_state()

	# The Zergling's two strongest proposals are aggressive fast-moves onto the
	# two adjacent Marines. These are the simultaneous responses the Marine AI
	# must cover without knowing which one will be chosen.
	var zerg_candidates := PureStatePlans.get_candidate_plans(state, "zerg", 8, 2)
	if zerg_candidates.size() != 2:
		tests._fail("expected exactly two retained Zergling response plans, got %d" % zerg_candidates.size())
		return false
	var response_targets: Array[Vector2i] = []
	for candidate_variant in zerg_candidates:
		if not (candidate_variant is Dictionary):
			continue
		var actions: Array = (candidate_variant as Dictionary).get("actions", [])
		if actions.size() != 1 or not (actions[0] is Dictionary):
			continue
		var action: Dictionary = actions[0]
		if str(action.get("action_key", "")) != "fast_move":
			continue
		response_targets.append(_cell_from_variant(action.get("end_point", [])))
	response_targets.sort_custom(func(a: Vector2i, b: Vector2i): return _cell_key(a) < _cell_key(b))
	var expected_targets: Array[Vector2i] = [Vector2i(1, -1), Vector2i(1, 0)]
	expected_targets.sort_custom(func(a: Vector2i, b: Vector2i): return _cell_key(a) < _cell_key(b))
	if response_targets != expected_targets:
		tests._fail("fixture expects top Zergling responses onto [1,-1] and [1,0], got %s" % response_targets)
		return false

	# M1/M2 begin adjacent to the Zergling at [0,0]. M3 is one ring farther out.
	# A Marine attack damages its primary target plus one direction-relative side
	# hex, so the robust joint plan can cover both predicted destinations without
	# requiring all Marines to guess the same tile.
	var result := PureStateOpponentResponseSearch.search(state, "terran", "zerg", 8, 40, 8, 2)
	if not bool(result.get("valid", false)):
		tests._fail("Marine opponent-response search should be valid")
		return false
	_print_results(tests, result, 8)

	var best_actions: Array = result.get("best_actions", [])
	var attack_actions: Array = []
	var primary_targets: Dictionary = {}
	var covered_cells: Dictionary = {}
	for action_variant in best_actions:
		if not (action_variant is Dictionary):
			continue
		var action: Dictionary = action_variant
		if str(action.get("action_key", "")) != "attack_short":
			continue
		attack_actions.append(action)
		var target := _cell_from_variant(action.get("end_point", []))
		primary_targets[_cell_key(target)] = true
		for damage_cell in _marine_damage_cells(state, action):
			covered_cells[_cell_key(damage_cell)] = true

	if attack_actions.size() < 2:
		tests._fail("expected at least two Marines to fire in the robust plan, got %s" % _plan_summary(best_actions))
		return false
	if primary_targets.size() < 2:
		tests._fail("expected spread fire across at least two primary targets, got %s" % _plan_summary(best_actions))
		return false
	for target in response_targets:
		if not covered_cells.has(_cell_key(target)):
			tests._fail("robust Marine fire should cover predicted Zergling destination %s; plan=%s covered=%s" % [
				target,
				_plan_summary(best_actions),
				covered_cells.keys(),
			])
			return false

	var worst_breakdown: Dictionary = result.get("best_worst_evaluation_breakdown", {})
	if float(worst_breakdown.get("terminal", 0.0)) <= 0.0:
		tests._fail("spread-fire plan should eliminate the 1-HP Zergling under either retained move: %s" % worst_breakdown)
		return false

	tests._log("  predicted Zergling destinations: %s" % response_targets)
	tests._log("  selected Marine plan: %s" % _plan_summary(best_actions))
	tests._log("  distinct primary targets=%d; covered cells=%s" % [primary_targets.size(), covered_cells.keys()])
	_print_runtime(tests, result)
	tests._pass("opponent modeling makes multiple Marines spread their two-tile fire across plausible Zergling moves")
	return true


static func _spread_fire_state() -> Dictionary:
	var zergling := _make_unit(4, "res://src/unit/definitions/zergling.tres", Vector2i(0, 0))
	zergling["health"] = 1
	return {
		"scenario_id": "test_marine_predictive_spread_fire",
		"hex_radius": 4,
		"groups": [
			{
				"name": "terran",
				"resources": {},
				"units": [
					_make_unit(1, "res://src/unit/definitions/marine.tres", Vector2i(1, 0)),
					_make_unit(2, "res://src/unit/definitions/marine.tres", Vector2i(1, -1)),
					_make_unit(3, "res://src/unit/definitions/marine.tres", Vector2i(2, -2)),
				],
			},
			{"name": "zerg", "resources": {}, "units": [zergling]},
		],
		"tile_resources": {},
	}


static func _marine_damage_cells(state: Dictionary, action: Dictionary) -> Array[Vector2i]:
	var found := TurnExecutionCore.find_unit_by_id(state, int(action.get("unit_id", -1)))
	if found.is_empty():
		return []
	var unit: Dictionary = found.get("unit", {})
	var from_cell := _cell_from_variant(unit.get("cell", []))
	var config: Dictionary = Actions.get_action_config("attack_short")
	var raw_cells: Array = TurnExecutionCore.get_damage_cells_for_config(
		from_cell.x,
		from_cell.y,
		action.get("path", []),
		action.get("end_point", []),
		config
	)
	var out: Array[Vector2i] = []
	for raw_cell in raw_cells:
		var cell := _cell_from_variant(raw_cell)
		if cell not in out:
			out.append(cell)
	var target := _cell_from_variant(action.get("end_point", []))
	var aoe: Dictionary = config.get("area_of_effect", {})
	for raw_aoe_cell in HexGrid.get_aoe_tiles(Vector2(from_cell.x, from_cell.y), Vector2(target.x, target.y), aoe):
		var aoe_cell := _cell_from_variant(raw_aoe_cell)
		if aoe_cell not in out:
			out.append(aoe_cell)
	return out


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


static func _print_results(tests: Node, result: Dictionary, limit: int) -> void:
	var ranked: Array = result.get("ranked_results", [])
	tests._log("  Marine robust results:")
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
	tests._log("  runtime Marine spread 40x2: %d simulations in %.1f ms (%.1f sims/sec), pruned=%d" % [
		simulations,
		elapsed_ms,
		sims_per_second,
		int(result.get("pruned_candidates", 0)),
	])


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
	return Vector2i(999, 999)


static func _cell_key(cell: Vector2i) -> String:
	return "%d,%d" % [cell.x, cell.y]
