extends RefCounted
## Tests for explainable pure-state evaluation and simulated tactical outcomes.

const PureStateEvaluator = preload("res://src/simulation/pure_state_evaluator.gd")
const PureStatePlans = preload("res://src/simulation/pure_state_plans.gd")
const PureStateSimulator = preload("res://src/simulation/pure_state_simulator.gd")
const TurnExecutionCore = preload("res://src/battle/turn_execution_core.gd")


static func run_all(tests: Node) -> bool:
	var ok := true
	ok = _test_evaluation_is_symmetric_and_monotonic(tests) and ok
	ok = _test_terminal_outcome_dominates(tests) and ok
	ok = _test_collapse_scenario_scores_winning_result(tests) and ok
	ok = _test_retreat_scenario_prefers_survival_after_simulation(tests) and ok
	return ok


static func _test_evaluation_is_symmetric_and_monotonic(tests: Node) -> bool:
	tests._log("test_pure_state_evaluator: symmetric and monotonic material/health/resources")
	var state := _balanced_fixture()
	var terran_score := PureStateEvaluator.evaluate(state, "terran")
	var zerg_score := PureStateEvaluator.evaluate(state, "zerg")
	if not is_equal_approx(terran_score, -zerg_score):
		tests._fail("two-sided evaluator should be symmetric; terran=%.2f zerg=%.2f" % [terran_score, zerg_score])
		return false

	var damaged := state.duplicate(true)
	damaged["groups"][1]["units"][0]["health"] = 2
	var damaged_score := PureStateEvaluator.evaluate(damaged, "terran")
	if damaged_score <= terran_score:
		tests._fail("damaging an enemy should improve evaluation; before=%.2f after=%.2f" % [terran_score, damaged_score])
		return false

	var killed := damaged.duplicate(true)
	killed["groups"][1]["units"][1]["health"] = 0
	var killed_score := PureStateEvaluator.evaluate(killed, "terran")
	if killed_score <= damaged_score:
		tests._fail("eliminating an enemy should improve evaluation; damaged=%.2f killed=%.2f" % [damaged_score, killed_score])
		return false

	var richer := killed.duplicate(true)
	richer["groups"][0]["resources"]["people"] = 2
	var richer_score := PureStateEvaluator.evaluate(richer, "terran")
	if richer_score <= killed_score:
		tests._fail("gaining group resources should improve evaluation; killed=%.2f richer=%.2f" % [killed_score, richer_score])
		return false
	tests._pass("evaluation is symmetric and increases with damage, kills, and resources")
	return true


static func _test_terminal_outcome_dominates(tests: Node) -> bool:
	tests._log("test_pure_state_evaluator: terminal outcome dominates positional components")
	var state := {
		"groups": [
			{"name": "terran", "resources": {}, "units": [
				_make_unit(1, "res://src/unit/definitions/marine.tres", Vector2i.ZERO),
			]},
			{"name": "zerg", "resources": {"crystal": 9999}, "units": []},
		]
	}
	var terran := PureStateEvaluator.evaluate_breakdown(state, "terran")
	var zerg := PureStateEvaluator.evaluate_breakdown(state, "zerg")
	if float(terran.get("terminal", 0.0)) <= 0.0 or float(terran.get("total", 0.0)) < 50000.0:
		tests._fail("living side should receive dominant terminal win value: %s" % terran)
		return false
	if float(zerg.get("terminal", 0.0)) >= 0.0 or float(zerg.get("total", 0.0)) > -50000.0:
		tests._fail("eliminated side should receive dominant terminal loss value: %s" % zerg)
		return false
	tests._pass("terminal win/loss dominates even extreme resource differences")
	return true


static func _test_collapse_scenario_scores_winning_result(tests: Node) -> bool:
	tests._log("test_pure_state_evaluator: 4-Zergling collapse winning result")
	var state := _pure_state_from_scenario("eval_phase_4zerglings_collapse_3marines")
	if state.is_empty():
		tests._fail("expected collapse scenario")
		return false
	var plans := PureStatePlans.get_candidate_plans(state, "zerg", 3, 50)
	if plans.is_empty():
		tests._fail("collapse scenario should generate candidate plans")
		return false
	var top_plan: Dictionary = plans[0]
	var before := PureStateEvaluator.evaluate_breakdown(state, "zerg")
	var result := PureStateSimulator.simulate_turn(state, {
		"terran": [],
		"zerg": top_plan.get("actions", []),
	})
	var after := PureStateEvaluator.evaluate_breakdown(result.get("next_state", {}), "zerg")
	tests._log("  collapse proposal=%.2f evaluator %.2f -> %.2f; after=%s" % [
		float(top_plan.get("proposal_score", 0.0)),
		float(before.get("total", 0.0)),
		float(after.get("total", 0.0)),
		_compact_breakdown(after),
	])
	if float(after.get("terminal", 0.0)) <= 0.0:
		tests._fail("simulated collapse should evaluate as a terminal Zerg win: %s" % after)
		return false
	if float(after.get("total", 0.0)) <= float(before.get("total", 0.0)):
		tests._fail("winning collapse result should score above starting position")
		return false
	tests._pass("winning collapse simulation receives dominant evaluator score")
	return true


static func _test_retreat_scenario_prefers_survival_after_simulation(tests: Node) -> bool:
	tests._log("test_pure_state_evaluator: retreat vs 3 Marines under fixed incoming fire")
	var state := _pure_state_from_scenario("eval_phase_zergling_retreat_vs_3marines")
	if state.is_empty():
		tests._fail("expected retreat scenario")
		return false

	# Ask the proposal layer for a wide set here so we can inspect both the cheap
	# proposal score and the evaluator score without top-3 pruning deciding the test.
	var plans := PureStatePlans.get_candidate_plans(state, "zerg", 10, 20)
	var retreat_targets := [Vector2i(-4, 3), Vector2i(-4, 2), Vector2i(-3, 3)]
	var retreat_plan: Dictionary = {}
	var stay_plan: Dictionary = {}
	for plan_variant in plans:
		var plan: Dictionary = plan_variant
		var actions: Array = plan.get("actions", [])
		if actions.size() != 1 or not (actions[0] is Dictionary):
			continue
		var action: Dictionary = actions[0]
		var action_key := str(action.get("action_key", ""))
		var target := _cell_from_variant(action.get("end_point", [0, 0]))
		if retreat_plan.is_empty() and action_key == "fast_move" and target in retreat_targets:
			retreat_plan = plan
		if stay_plan.is_empty() and action_key == "reload":
			stay_plan = plan
	if retreat_plan.is_empty() or stay_plan.is_empty():
		tests._fail("expected both generated retreat and reload/stay plans; retreat=%s stay=%s" % [retreat_plan, stay_plan])
		return false

	# Scenario unit IDs are 1..3 Marines followed by unit 4 Zergling. All Marines
	# fire at the Zergling's old tile, matching the drill's stated timing pressure.
	var marine_actions: Array = []
	for unit_id in [1, 2, 3]:
		marine_actions.append({
			"unit_id": unit_id,
			"action_key": "attack_short",
			"path": [],
			"end_point": [-3, 2],
		})

	var stay_result := PureStateSimulator.simulate_turn(state, {
		"terran": marine_actions,
		"zerg": stay_plan.get("actions", []),
	})
	var retreat_result := PureStateSimulator.simulate_turn(state, {
		"terran": marine_actions,
		"zerg": retreat_plan.get("actions", []),
	})
	var stay_eval := PureStateEvaluator.evaluate_breakdown(stay_result.get("next_state", {}), "zerg")
	var retreat_eval := PureStateEvaluator.evaluate_breakdown(retreat_result.get("next_state", {}), "zerg")
	tests._log("  stay proposal=%.2f eval=%.2f %s" % [
		float(stay_plan.get("proposal_score", 0.0)),
		float(stay_eval.get("total", 0.0)),
		_compact_breakdown(stay_eval),
	])
	tests._log("  retreat proposal=%.2f eval=%.2f %s" % [
		float(retreat_plan.get("proposal_score", 0.0)),
		float(retreat_eval.get("total", 0.0)),
		_compact_breakdown(retreat_eval),
	])
	if int(stay_eval.get("friendly_units", -1)) != 0:
		tests._fail("Zergling that stays under three Marine attacks should be eliminated: %s" % stay_eval)
		return false
	if int(retreat_eval.get("friendly_units", 0)) != 1:
		tests._fail("retreating Zergling should survive: %s" % retreat_eval)
		return false
	if float(retreat_eval.get("total", 0.0)) <= float(stay_eval.get("total", 0.0)):
		tests._fail("evaluator should prefer surviving retreat over staying under lethal fire")
		return false
	tests._pass("simulated retreat survives and evaluator outranks the lethal stay result")
	return true


static func _balanced_fixture() -> Dictionary:
	return {
		"groups": [
			{
				"name": "terran",
				"resources": {"crystal": 1},
				"units": [
					_make_unit(1, "res://src/unit/definitions/zergling.tres", Vector2i(0, 0)),
					_make_unit(2, "res://src/unit/definitions/zergling.tres", Vector2i(0, 1)),
				],
			},
			{
				"name": "zerg",
				"resources": {"crystal": 1},
				"units": [
					_make_unit(3, "res://src/unit/definitions/zergling.tres", Vector2i(2, 0)),
					_make_unit(4, "res://src/unit/definitions/zergling.tres", Vector2i(2, 1)),
				],
			},
		]
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


static func _cell_from_variant(value: Variant) -> Vector2i:
	if value is Vector2i:
		return value
	if value is Vector2:
		return Vector2i(int(value.x), int(value.y))
	if value is Array and value.size() >= 2:
		return Vector2i(int(value[0]), int(value[1]))
	return Vector2i.ZERO


static func _compact_breakdown(breakdown: Dictionary) -> String:
	return "terminal=%.0f units=%.0f hp=%.0f resources=%.0f energy=%.0f" % [
		float(breakdown.get("terminal", 0.0)),
		float(breakdown.get("unit_count", 0.0)),
		float(breakdown.get("health", 0.0)),
		float(breakdown.get("resources", 0.0)),
		float(breakdown.get("energy", 0.0)),
	]
