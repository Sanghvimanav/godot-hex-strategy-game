extends RefCounted
## Diagnostic baselines for one-turn search on tactical eval scenarios.
##
## Hard assertions are used when the tactic is unambiguously correct under the
## current rules. Characterization cases record known evaluator/search gaps so a
## later intelligence improvement produces a visible before/after signal.

const PureStateOneTurnSearch = preload("res://src/simulation/pure_state_one_turn_search.gd")
const TurnExecutionCore = preload("res://src/battle/turn_execution_core.gd")


static func run_all(tests: Node) -> bool:
	var ok := true
	ok = _test_baneling_obvious_multi_kill(tests) and ok
	ok = _baseline_baneling_favorable_nonlethal_sacrifice(tests) and ok
	ok = _baseline_marine_aoe(tests, "eval_marine_aoe_branch_zerg_to_neg11", Vector2i(-1, -1)) and ok
	ok = _baseline_marine_aoe(tests, "eval_marine_aoe_branch_zerg_to_neg1neg2", Vector2i(-1, -2)) and ok
	ok = _baseline_scout_target_priority(tests) and ok
	return ok


## True sacrifice regression: the Baneling is not the final Zerg unit and both
## stacked Marines are at 2 HP, so explode kills both enemies and produces an
## immediate terminal win. Search must choose it.
static func _test_baneling_obvious_multi_kill(tests: Node) -> bool:
	const CASE_ID := "baneling_obvious_multi_kill"
	tests._log("test_one_turn_search_baselines: Baneling obvious multi-kill sacrifice")
	var state := _baneling_fixture(2, 4)
	var result := PureStateOneTurnSearch.search(state, "zerg")
	if not _validate_search_result(tests, CASE_ID, result):
		return false
	_print_top_results(tests, result, 5)
	var expected := _expected_status(result, "explode", Vector2i(0, 0))
	if not bool(expected.get("candidate_present", false)):
		tests._fail("obvious Baneling explode should survive candidate generation")
		return false
	if not bool(expected.get("selected", false)):
		tests._fail("Baneling should explode when it kills both 2-HP Marines while another Zerg unit survives")
		return false
	var best_eval := float(result.get("best_evaluation_score", 0.0))
	var breakdown: Dictionary = result.get("best_evaluation_breakdown", {})
	if float(breakdown.get("terminal", 0.0)) <= 0.0:
		tests._fail("obvious Baneling multi-kill should resolve to a terminal Zerg win, got eval=%.2f breakdown=%s" % [
			best_eval,
			str(breakdown),
		])
		return false
	tests._log("  selected explode -> [0,0], eval=%.2f terminal=%.2f" % [
		best_eval,
		float(breakdown.get("terminal", 0.0)),
	])
	tests._pass("Baneling chooses a real multi-kill sacrifice that immediately wins")
	return true


## Evaluator characterization: a nearly-dead 1-HP Baneling can trade itself for
## four points of damage across two 3-HP Marines while another Zerg unit remains.
## The current generic evaluator usually prefers preserving the extra unit count;
## this case records that gap without asserting that explode must already be chosen.
static func _baseline_baneling_favorable_nonlethal_sacrifice(tests: Node) -> bool:
	const CASE_ID := "baneling_favorable_nonlethal_sacrifice"
	tests._log("test_one_turn_search_baselines: Baneling favorable nonlethal sacrifice")
	var state := _baneling_fixture(3, 1)
	var result := PureStateOneTurnSearch.search(state, "zerg")
	if not _validate_search_result(tests, CASE_ID, result):
		return false
	_print_top_results(tests, result, 5)
	var expected := _expected_status(result, "explode", Vector2i(0, 0))
	if not bool(expected.get("candidate_present", false)):
		tests._fail("favorable Baneling explode must remain present so this measures evaluator choice, not proposal recall")
		return false
	var explode_result := _find_result_with_action(result, "explode", Vector2i(0, 0))
	var explode_eval := float(explode_result.get("evaluation_score", 0.0))
	var best_eval := float(result.get("best_evaluation_score", 0.0))
	tests._log("  explode selected=%s; best eval=%.2f; explode eval=%.2f" % [
		str(expected.get("selected", false)),
		best_eval,
		explode_eval,
	])
	if bool(expected.get("selected", false)):
		tests._log("  evaluator/search now values the nearly-dead Baneling sacrifice; characterization gap has improved")
	else:
		tests._log("  current evaluator still prefers preserving unit count over trading a 1-HP Baneling for 4 Marine damage")
	tests._pass("Baneling nonlethal sacrifice evaluator baseline recorded with explode candidate present")
	return true


static func _baseline_marine_aoe(tests: Node, scenario_id: String, zerg_move_target: Vector2i) -> bool:
	tests._log("test_one_turn_search_baselines: Marine AOE %s" % scenario_id)
	var state := _pure_state_from_scenario(scenario_id)
	if state.is_empty():
		tests._fail("missing scenario %s" % scenario_id)
		return false
	var zergling_id := _find_unit_id_by_def(state, "zerg", "zergling.tres")
	if zergling_id < 0:
		tests._fail("%s should contain scripted Zergling" % scenario_id)
		return false
	var scripted_zerg := [{
		"unit_id": zergling_id,
		"action_key": "fast_move",
		"path": [[zerg_move_target.x, zerg_move_target.y]],
		"end_point": [zerg_move_target.x, zerg_move_target.y],
	}]
	var result := PureStateOneTurnSearch.search(state, "terran", {"zerg": scripted_zerg})
	if not _validate_search_result(tests, scenario_id, result):
		return false
	_print_top_results(tests, result, 5)
	var expected := _expected_status(result, "attack_short", Vector2i(-1, -1))
	tests._log("  expected attack_short -> [-1,-1]: selected=%s candidate_present=%s" % [
		str(expected["selected"]), str(expected["candidate_present"]),
	])
	tests._pass("Marine AOE baseline recorded for %s" % scenario_id)
	return true


static func _baseline_scout_target_priority(tests: Node) -> bool:
	const SCENARIO_ID := "eval_scout_prioritize_zergling_over_mountain"
	tests._log("test_one_turn_search_baselines: Scout prioritizes moving Zergling over Mountain")
	var state := _pure_state_from_scenario(SCENARIO_ID)
	if state.is_empty():
		tests._fail("missing scenario %s" % SCENARIO_ID)
		return false
	var zergling_id := _find_unit_id_by_def(state, "zerg", "zergling.tres")
	if zergling_id < 0:
		tests._fail("%s should contain scripted Zergling" % SCENARIO_ID)
		return false
	var scripted_zerg := [{
		"unit_id": zergling_id,
		"action_key": "fast_move",
		"path": [[3, -3]],
		"end_point": [3, -3],
	}]
	var result := PureStateOneTurnSearch.search(state, "terran", {"zerg": scripted_zerg})
	if not _validate_search_result(tests, SCENARIO_ID, result):
		return false
	_print_top_results(tests, result, 8)
	var expected := _expected_status(result, "attack_ray", Vector2i(3, -3))
	tests._log("  expected attack_ray -> [3,-3]: selected=%s candidate_present=%s" % [
		str(expected["selected"]), str(expected["candidate_present"]),
	])
	tests._pass("Scout target-priority baseline recorded")
	return true


static func _validate_search_result(tests: Node, scenario_id: String, result: Dictionary) -> bool:
	if not bool(result.get("valid", false)):
		tests._fail("%s should produce a valid one-turn search" % scenario_id)
		return false
	var candidate_count := int(result.get("candidates_considered", 0))
	if candidate_count <= 0 or candidate_count > PureStateOneTurnSearch.DEFAULT_MAX_PLANS:
		tests._fail("%s candidate count should be within 1..%d, got %d" % [
			scenario_id, PureStateOneTurnSearch.DEFAULT_MAX_PLANS, candidate_count,
		])
		return false
	return true


static func _expected_status(result: Dictionary, action_key: String, target: Vector2i) -> Dictionary:
	var selected := false
	for action_variant in result.get("best_actions", []):
		if action_variant is Dictionary and _action_matches(action_variant, action_key, target):
			selected = true
			break
	var candidate_present := false
	for item_variant in result.get("ranked_results", []):
		if not (item_variant is Dictionary):
			continue
		for action_variant in item_variant.get("actions", []):
			if action_variant is Dictionary and _action_matches(action_variant, action_key, target):
				candidate_present = true
				break
		if candidate_present:
			break
	return {"selected": selected, "candidate_present": candidate_present}


static func _find_result_with_action(result: Dictionary, action_key: String, target: Vector2i) -> Dictionary:
	for item_variant in result.get("ranked_results", []):
		if not (item_variant is Dictionary):
			continue
		var item: Dictionary = item_variant
		for action_variant in item.get("actions", []):
			if action_variant is Dictionary and _action_matches(action_variant, action_key, target):
				return item
	return {}


static func _action_matches(action: Dictionary, action_key: String, target: Vector2i) -> bool:
	return str(action.get("action_key", "")) == action_key \
		and _cell_from_variant(action.get("end_point", [])) == target


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
		if not (action_variant is Dictionary):
			continue
		var action: Dictionary = action_variant
		parts.append("U%d %s -> %s" % [
			int(action.get("unit_id", -1)),
			str(action.get("action_key", "")),
			str(action.get("end_point", [])),
		])
	return "; ".join(parts)


## Baneling-specific tactical fixture used by both sacrifice tests. Marines and
## Baneling are stacked on [0,0]; a second Zergling is safely outside the blast
## so Baneling self-sacrifice does not automatically eliminate the Zerg side.
static func _baneling_fixture(marine_health: int, baneling_health: int) -> Dictionary:
	var marine_a := _make_unit(1, "res://src/unit/definitions/marine.tres", Vector2i(0, 0))
	var marine_b := _make_unit(2, "res://src/unit/definitions/marine.tres", Vector2i(0, 0))
	marine_a["health"] = marine_health
	marine_b["health"] = marine_health
	var baneling := _make_unit(3, "res://src/unit/definitions/baneling.tres", Vector2i(0, 0))
	baneling["health"] = baneling_health
	var survivor := _make_unit(4, "res://src/unit/definitions/zergling.tres", Vector2i(4, 0))
	return {
		"scenario_id": "test_baneling_sacrifice_fixture",
		"hex_radius": 5,
		"groups": [
			{"name": "terran", "resources": {}, "units": [marine_a, marine_b]},
			{"name": "zerg", "ai": true, "resources": {}, "units": [baneling, survivor]},
		],
		"tile_resources": {},
	}


static func _find_unit_id_by_def(state: Dictionary, group_name: String, filename: String) -> int:
	for group_variant in state.get("groups", []):
		if not (group_variant is Dictionary):
			continue
		var group: Dictionary = group_variant
		if str(group.get("name", "")) != group_name:
			continue
		for unit_variant in group.get("units", []):
			if not (unit_variant is Dictionary):
				continue
			var unit: Dictionary = unit_variant
			if str(unit.get("def_path", "")).ends_with(filename):
				return int(unit.get("unit_id", -1))
	return -1


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
