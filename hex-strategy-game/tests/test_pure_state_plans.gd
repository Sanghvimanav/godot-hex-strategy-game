extends RefCounted
## Tests for bounded pure-state joint plan generation, including one real scenario.

const PureStatePlans = preload("res://src/simulation/pure_state_plans.gd")
const PureStateSimulator = preload("res://src/simulation/pure_state_simulator.gd")
const TurnExecutionCore = preload("res://src/battle/turn_execution_core.gd")


static func run_all(tests: Node) -> bool:
	var ok := true
	ok = _test_plan_generation_is_bounded_complete_and_pure(tests) and ok
	ok = _test_focus_and_split_fire_survive_pruning(tests) and ok
	ok = _test_existing_zergling_collapse_scenario(tests) and ok
	return ok


static func _test_plan_generation_is_bounded_complete_and_pure(tests: Node) -> bool:
	tests._log("test_pure_state_plans: bounded complete plans without mutation")
	var state := _two_scout_two_target_fixture()
	var original := state.duplicate(true)
	var plans := PureStatePlans.get_candidate_plans(state, "terran", 3, 5)
	if state != original:
		tests._fail("candidate plan generation should not mutate game state")
		return false
	if plans.is_empty() or plans.size() > 5:
		tests._fail("expected 1..5 bounded plans, got %d" % plans.size())
		return false
	for plan_variant in plans:
		var plan: Dictionary = plan_variant
		var actions: Array = plan.get("actions", [])
		if actions.size() != 2:
			tests._fail("each plan should contain one action for each of the two Scouts: %s" % plan)
			return false
		if not plan.has("proposal_score"):
			tests._fail("candidate plan should expose proposal_score")
			return false
	tests._pass("plan generation is bounded, complete, and pure")
	return true


static func _test_focus_and_split_fire_survive_pruning(tests: Node) -> bool:
	tests._log("test_pure_state_plans: focus + split fire diversity")
	var plans := PureStatePlans.get_candidate_plans(_two_scout_two_target_fixture(), "terran", 3, 20)
	var target_a := Vector2i(2, 0)
	var target_b := Vector2i(0, 2)
	var focus_a := false
	var focus_b := false
	var split := false
	for plan_variant in plans:
		var plan: Dictionary = plan_variant
		var attacks: Array[Vector2i] = []
		for action_variant in plan.get("actions", []):
			if not (action_variant is Dictionary):
				continue
			var action: Dictionary = action_variant
			if str(action.get("action_key", "")) != "attack_ray":
				continue
			attacks.append(_cell_from_variant(action.get("end_point", [0, 0])))
		if attacks.size() != 2:
			continue
		focus_a = focus_a or (attacks[0] == target_a and attacks[1] == target_a)
		focus_b = focus_b or (attacks[0] == target_b and attacks[1] == target_b)
		split = split or ((attacks[0] == target_a and attacks[1] == target_b) or (attacks[0] == target_b and attacks[1] == target_a))
	if not focus_a or not focus_b or not split:
		tests._fail("pruning should preserve focus-fire and split-fire hypotheses (focus_a=%s focus_b=%s split=%s)" % [focus_a, focus_b, split])
		return false
	tests._pass("focus-fire and split-fire plans both survive pruning")
	return true


static func _test_existing_zergling_collapse_scenario(tests: Node) -> bool:
	tests._log("test_pure_state_plans: existing eval_phase_4zerglings_collapse_3marines scenario")
	var state := _pure_state_from_scenario("eval_phase_4zerglings_collapse_3marines")
	if state.is_empty():
		tests._fail("expected existing collapse scenario to be available")
		return false
	var plans := PureStatePlans.get_candidate_plans(state, "zerg", 3, 50)
	if plans.is_empty() or plans.size() > 50:
		tests._fail("scenario should produce bounded candidate plans, got %d" % plans.size())
		return false

	var shown := mini(5, plans.size())
	tests._log("top %d candidate plans:" % shown)
	for i in range(shown):
		var ranked_plan: Dictionary = plans[i]
		tests._log("  #%d score=%.2f %s" % [
			i + 1,
			float(ranked_plan.get("proposal_score", 0.0)),
			_format_actions(ranked_plan.get("actions", [])),
		])

	var collapse_cell := Vector2i(-2, 1)
	var top_plan: Dictionary = plans[0]
	if not _is_four_zergling_collapse(top_plan, collapse_cell):
		tests._fail("expected coordinated four-Zergling collapse to rank #1; top=%s" % top_plan)
		return false

	var collapse_plan: Dictionary = {}
	for plan_variant in plans:
		var plan: Dictionary = plan_variant
		if _is_four_zergling_collapse(plan, collapse_cell):
			collapse_plan = plan
			break

	if collapse_plan.is_empty():
		tests._fail("candidate set should include the scenario's coordinated four-Zergling collapse onto [-2,1]")
		return false

	var terran_before := _group_units(state, "terran").size()
	var zerg_before := _group_units(state, "zerg").size()
	var result := PureStateSimulator.simulate_turn(state, {
		"terran": [],
		"zerg": top_plan.get("actions", []),
	})
	var remaining_terran := _group_units(result.get("next_state", {}), "terran")
	var remaining_zerg := _group_units(result.get("next_state", {}), "zerg")
	tests._log("top plan simulation: Terran %d -> %d units; Zerg %d -> %d units" % [
		terran_before,
		remaining_terran.size(),
		zerg_before,
		remaining_zerg.size(),
	])
	if not remaining_terran.is_empty():
		tests._fail("simulating the top-ranked generated collapse plan should eliminate the three stacked Marines; remaining=%s" % remaining_terran)
		return false
	tests._pass("real scenario ranks the coordinated winning collapse #1 and simulator resolves it")
	return true


static func _is_four_zergling_collapse(plan: Dictionary, collapse_cell: Vector2i) -> bool:
	var actions: Array = plan.get("actions", [])
	if actions.size() != 4:
		return false
	for action_variant in actions:
		if not (action_variant is Dictionary):
			return false
		var action: Dictionary = action_variant
		if str(action.get("action_key", "")) != "fast_move":
			return false
		if _cell_from_variant(action.get("end_point", [0, 0])) != collapse_cell:
			return false
	return true


static func _format_actions(actions: Array) -> String:
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


static func _two_scout_two_target_fixture() -> Dictionary:
	return {
		"hex_radius": 5,
		"groups": [
			{
				"name": "terran",
				"ai": true,
				"units": [
					_make_unit(1, "res://src/unit/definitions/scout.tres", Vector2i(0, 0)),
					_make_unit(2, "res://src/unit/definitions/scout.tres", Vector2i(0, 0)),
				],
			},
			{
				"name": "zerg",
				"ai": false,
				"units": [
					_make_unit(3, "res://src/unit/definitions/zergling.tres", Vector2i(2, 0)),
					_make_unit(4, "res://src/unit/definitions/zergling.tres", Vector2i(0, 2)),
				],
			},
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


static func _group_units(game_state: Dictionary, group_name: String) -> Array:
	for group_variant in game_state.get("groups", []):
		if group_variant is Dictionary and str(group_variant.get("name", "")) == group_name:
			return group_variant.get("units", [])
	return []


static func _cell_from_variant(value: Variant) -> Vector2i:
	if value is Vector2i:
		return value
	if value is Vector2:
		return Vector2i(int(value.x), int(value.y))
	if value is Array and value.size() >= 2:
		return Vector2i(int(value[0]), int(value[1]))
	return Vector2i.ZERO
