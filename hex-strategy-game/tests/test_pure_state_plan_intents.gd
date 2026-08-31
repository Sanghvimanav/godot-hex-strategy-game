extends RefCounted
## Tests for shared commit / hold / reposition / disengage intent buckets.

const PureStatePlans = preload("res://src/simulation/pure_state_plans.gd")
const PureStatePlanIntents = preload("res://src/simulation/pure_state_plan_intents.gd")
const PureStateOpponentResponseSearch = preload("res://src/simulation/pure_state_opponent_response_search.gd")
const TurnExecutionCore = preload("res://src/battle/turn_execution_core.gd")


static func run_all(tests: Node) -> bool:
	var ok := true
	ok = _test_zergling_actions_cover_four_intents(tests) and ok
	ok = _test_own_and_opponent_selection_policies(tests) and ok
	ok = _test_response_search_uses_four_way_diversity(tests) and ok
	return ok


static func _test_zergling_actions_cover_four_intents(tests: Node) -> bool:
	tests._log("test_pure_state_plan_intents: classify commit/hold/reposition/disengage")
	var state := _zergling_vs_marine_state()
	var zergling := _find_unit(state, 2)
	var examples := {
		PureStatePlanIntents.COMMIT: _action(2, "fast_move", Vector2i(-1, 0)),
		PureStatePlanIntents.HOLD: _action(2, "reload", Vector2i(-2, 1)),
		PureStatePlanIntents.REPOSITION: _action(2, "fast_move", Vector2i(-2, 0)),
		PureStatePlanIntents.DISENGAGE: _action(2, "fast_move", Vector2i(-3, 1)),
	}
	for expected_intent in examples.keys():
		var actual := PureStatePlanIntents.classify_action(
			state,
			"zerg",
			zergling,
			examples[expected_intent]
		)
		if actual != expected_intent:
			tests._fail("expected %s action to classify as %s, got %s" % [
				examples[expected_intent],
				expected_intent,
				actual,
			])
			return false
	tests._pass("Zergling movement geometry and hold action map cleanly to all four intent buckets")
	return true


static func _test_own_and_opponent_selection_policies(tests: Node) -> bool:
	tests._log("test_pure_state_plan_intents: own quality floor + opponent diversity quotas")
	var state := _zergling_vs_marine_state()
	# One Zergling has six fast-move destinations plus reload. With an action budget
	# of seven, the source pool contains two commits, one hold, two lateral
	# repositions, and two disengages.
	var pool := PureStatePlans.get_candidate_plans(state, "zerg", 7, 7, true)
	if pool.size() != 7:
		tests._fail("expected seven one-unit Zergling plans, got %d" % pool.size())
		return false

	var own := PureStatePlanIntents.select_own_candidates(state, "zerg", pool, 4)
	var own_counts := PureStatePlanIntents.count_intents(own)
	for bucket in PureStatePlanIntents.BUCKET_ORDER:
		if int(own_counts.get(bucket, 0)) != 1:
			tests._fail("own four-plan diversity floor should retain one %s plan: %s" % [bucket, own_counts])
			return false

	var opponent := PureStatePlanIntents.select_opponent_candidates(state, "zerg", pool, 7)
	var opponent_counts := PureStatePlanIntents.count_intents(opponent)
	var expected := {
		PureStatePlanIntents.COMMIT: 2,
		PureStatePlanIntents.HOLD: 1,
		PureStatePlanIntents.REPOSITION: 2,
		PureStatePlanIntents.DISENGAGE: 2,
	}
	if opponent_counts != expected:
		tests._fail("seven-plan opponent policy should retain 2/1/2/2 intent coverage; expected=%s actual=%s" % [expected, opponent_counts])
		return false

	tests._log("  own 4-plan intents: %s" % own_counts)
	tests._log("  opponent 7-plan intents: %s" % opponent_counts)
	tests._pass("own plans stay quality-heavy with a diversity floor while opponent plans enforce stronger coverage")
	return true


static func _test_response_search_uses_four_way_diversity(tests: Node) -> bool:
	tests._log("test_pure_state_plan_intents: response search wires diversity to both sides")
	var result := PureStateOpponentResponseSearch.search(
		_zergling_vs_marine_state(),
		"zerg",
		"terran",
		7,
		4,
		13,
		4
	)
	if not bool(result.get("valid", false)):
		tests._fail("expected valid response search for diversity integration fixture")
		return false
	var own_counts: Dictionary = result.get("own_candidate_intent_counts", {})
	var opponent_counts: Dictionary = result.get("opponent_candidate_intent_counts", {})
	for bucket in PureStatePlanIntents.BUCKET_ORDER:
		if int(own_counts.get(bucket, 0)) != 1:
			tests._fail("4-plan own response-search set should contain one %s candidate: %s" % [bucket, own_counts])
			return false
		if int(opponent_counts.get(bucket, 0)) != 1:
			tests._fail("4-plan opponent response-search set should contain one %s candidate: %s" % [bucket, opponent_counts])
			return false
	if int(result.get("simulations_run", 0)) > 16:
		tests._fail("four-by-four diverse integration search should remain bounded to 16 simulations")
		return false
	tests._log("  response-search own intents: %s" % own_counts)
	tests._log("  response-search opponent intents: %s" % opponent_counts)
	tests._pass("opponent-response search applies the shared four-bucket vocabulary to both candidate sets")
	return true


static func _zergling_vs_marine_state() -> Dictionary:
	return {
		"scenario_id": "test_plan_intent_geometry",
		"hex_radius": 5,
		"groups": [
			{
				"name": "terran",
				"resources": {},
				"units": [_make_unit(1, "res://src/unit/definitions/marine.tres", Vector2i(0, 0))],
			},
			{
				"name": "zerg",
				"resources": {},
				"units": [_make_unit(2, "res://src/unit/definitions/zergling.tres", Vector2i(-2, 1))],
			},
		],
		"tile_resources": {},
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


static func _find_unit(state: Dictionary, unit_id: int) -> Dictionary:
	var found := TurnExecutionCore.find_unit_by_id(state, unit_id)
	return found.get("unit", {})


static func _action(unit_id: int, action_key: String, end_point: Vector2i) -> Dictionary:
	return {
		"unit_id": unit_id,
		"action_key": action_key,
		"end_point": [end_point.x, end_point.y],
		"path": [],
	}
