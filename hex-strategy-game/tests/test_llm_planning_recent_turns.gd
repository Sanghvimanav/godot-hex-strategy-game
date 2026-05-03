extends RefCounted

static func run_all(tests: Node) -> bool:
	var ok := true
	ok = _test_last_two_and_compact(tests) and ok
	ok = _test_empty_history(tests) and ok
	ok = _test_fov_filters_enemy_actions(tests) and ok
	ok = _test_fov_includes_ai_own_actions(tests) and ok
	ok = _test_fov_includes_action_if_source_or_dest_visible(tests) and ok
	ok = _test_fov_filters_died_unit_ids(tests) and ok
	ok = _test_damage_by_id_and_effects_filtered(tests) and ok
	ok = _test_fov_cells_sorted(tests) and ok
	ok = _test_compact_action_includes_from_cell(tests) and ok
	return ok

static func _test_empty_history(tests: Node) -> bool:
	tests._log("test_llm_planning_recent_turns: empty_history")
	var r: Array = LlmPlanningRecentTurns.build_from_history([])
	if not r.is_empty():
		tests._fail("empty history should yield []")
		return false
	tests._pass("empty_history")
	return true

static func _test_last_two_and_compact(tests: Node) -> bool:
	tests._log("test_llm_planning_recent_turns: last_two_and_compact")
	var hist: Array = []
	for t in range(1, 9):
		hist.append({
			"turn": t,
			"recording": {
				"died_ids": [t * 10],
				"actions": [
					{
						"unit_id": 100 + t,
						"unit_name": "Marine",
						"type": "move" if t % 2 == 0 else "ability",
						"action_key": "attack" if t % 2 == 1 else "",
						"path": [[0, 0], [1, 1]],
					}
				],
			},
		})
	var out: Array = LlmPlanningRecentTurns.build_from_history(hist)
	if out.size() != 2:
		tests._fail("expected 2 turns kept, got %d" % out.size())
		return false
	var first: Dictionary = out[0] as Dictionary
	if int(first.get("turn", 0)) != 7:
		tests._fail("oldest kept turn should be 7, got %s" % str(first.get("turn")))
		return false
	var last: Dictionary = out[out.size() - 1] as Dictionary
	if int(last.get("turn", 0)) != 8:
		tests._fail("newest turn should be 8")
		return false
	var acts: Array = last.get("actions", []) as Array
	if acts.is_empty():
		tests._fail("expected actions")
		return false
	var a0: Dictionary = acts[0] as Dictionary
	if not a0.has("end"):
		tests._fail("move should have end from path tail")
		return false
	tests._pass("last_two_and_compact")
	return true


static func _test_fov_filters_enemy_actions(tests: Node) -> bool:
	tests._log("test_llm_planning_recent_turns: fov_filters_enemy_actions")
	var ai_fov := {"0,0": true, "1,0": true}
	var ai_unit_ids := [100]
	var hist: Array = [{
		"turn": 1,
		"recording": {
			"died_ids": [],
			"actions": [
				{"unit_id": 200, "unit_name": "Enemy", "type": "move", "from_cell": [5, 5], "path": [[5, 5], [6, 6]]},
			],
		},
		"ai_fov": ai_fov,
		"ai_unit_ids": ai_unit_ids,
	}]
	var out: Array = LlmPlanningRecentTurns.build_from_history(hist)
	var turn: Dictionary = out[0] as Dictionary
	var acts: Array = turn.get("actions", []) as Array
	if not acts.is_empty():
		tests._fail("enemy action outside FOV should be filtered out")
		return false
	tests._pass("fov_filters_enemy_actions")
	return true


static func _test_fov_includes_ai_own_actions(tests: Node) -> bool:
	tests._log("test_llm_planning_recent_turns: fov_includes_ai_own_actions")
	var ai_fov := {"0,0": true}
	var ai_unit_ids := [100]
	var hist: Array = [{
		"turn": 1,
		"recording": {
			"died_ids": [],
			"actions": [
				{"unit_id": 100, "unit_name": "MyUnit", "type": "move", "from_cell": [99, 99], "path": [[99, 99], [88, 88]]},
			],
		},
		"ai_fov": ai_fov,
		"ai_unit_ids": ai_unit_ids,
	}]
	var out: Array = LlmPlanningRecentTurns.build_from_history(hist)
	var turn: Dictionary = out[0] as Dictionary
	var acts: Array = turn.get("actions", []) as Array
	if acts.size() != 1:
		tests._fail("AI's own action should always be included even if outside FOV")
		return false
	tests._pass("fov_includes_ai_own_actions")
	return true


static func _test_fov_includes_action_if_source_or_dest_visible(tests: Node) -> bool:
	tests._log("test_llm_planning_recent_turns: fov_includes_action_if_source_or_dest_visible")
	var ai_fov := {"3,3": true}
	var ai_unit_ids := [100]
	var hist: Array = [{
		"turn": 1,
		"recording": {
			"died_ids": [],
			"actions": [
				{"unit_id": 201, "unit_name": "EnemyA", "type": "move", "from_cell": [3, 3], "path": [[3, 3], [9, 9]]},
				{"unit_id": 202, "unit_name": "EnemyB", "type": "move", "from_cell": [9, 9], "path": [[9, 9], [3, 3]]},
				{"unit_id": 203, "unit_name": "EnemyC", "type": "move", "from_cell": [8, 8], "path": [[8, 8], [7, 7]]},
			],
		},
		"ai_fov": ai_fov,
		"ai_unit_ids": ai_unit_ids,
	}]
	var out: Array = LlmPlanningRecentTurns.build_from_history(hist)
	var turn: Dictionary = out[0] as Dictionary
	var acts: Array = turn.get("actions", []) as Array
	if acts.size() != 2:
		tests._fail("expected 2 actions (source or dest in FOV), got %d" % acts.size())
		return false
	var ids: Array = []
	for a in acts:
		ids.append(int((a as Dictionary).get("unit_id", 0)))
	if 201 not in ids or 202 not in ids:
		tests._fail("expected unit 201 (source visible) and 202 (dest visible)")
		return false
	if 203 in ids:
		tests._fail("unit 203 should be filtered (neither source nor dest in FOV)")
		return false
	tests._pass("fov_includes_action_if_source_or_dest_visible")
	return true


static func _test_fov_filters_died_unit_ids(tests: Node) -> bool:
	tests._log("test_llm_planning_recent_turns: fov_filters_died_unit_ids")
	var ai_fov := {"2,2": true}
	var ai_unit_ids := [100]
	var hist: Array = [{
		"turn": 1,
		"recording": {
			"died_ids": [100, 300, 400],
			"actions": [
				{"unit_id": 300, "unit_name": "VisibleEnemy", "type": "ability", "caster_cell": [2, 2]},
			],
		},
		"ai_fov": ai_fov,
		"ai_unit_ids": ai_unit_ids,
	}]
	var out: Array = LlmPlanningRecentTurns.build_from_history(hist)
	var turn: Dictionary = out[0] as Dictionary
	var died: Array = turn.get("died_unit_ids", []) as Array
	if 100 not in died:
		tests._fail("AI's own unit death should always be reported")
		return false
	if 300 not in died:
		tests._fail("enemy that was visible (had action in FOV) should be reported dead")
		return false
	if 400 in died:
		tests._fail("enemy 400 was never visible - death should be filtered")
		return false
	tests._pass("fov_filters_died_unit_ids")
	return true


static func _test_damage_by_id_and_effects_filtered(tests: Node) -> bool:
	tests._log("test_llm_planning_recent_turns: damage_by_id_and_effects_filtered")
	var ai_fov := {"2,2": true}
	var ai_unit_ids := [100]
	var hist: Array = [{
		"turn": 1,
		"recording": {
			"died_ids": [],
			"damage_by_id": {100: 2, 200: 1, 300: 3},
			"applied_effects": [
				{"unit_id": 100, "effect": {"kind": "Stun", "duration": 1, "params": {}}},
				{"unit_id": 200, "effect": {"kind": "Stun", "duration": 1, "params": {}}},
				{"unit_id": 400, "effect": {"kind": "Stun", "duration": 1, "params": {}}},
			],
			"actions": [
				{"unit_id": 200, "unit_name": "Enemy", "type": "ability", "caster_cell": [2, 2]},
			],
		},
		"ai_fov": ai_fov,
		"ai_unit_ids": ai_unit_ids,
	}]
	var out: Array = LlmPlanningRecentTurns.build_from_history(hist)
	var turn: Dictionary = out[0] as Dictionary
	var dmg: Dictionary = turn.get("damage_by_id", {}) as Dictionary
	if int(dmg.get(100, 0)) != 2:
		tests._fail("AI unit damage should always be visible")
		return false
	if int(dmg.get(200, 0)) != 1:
		tests._fail("enemy 200 had visible action — damage should be included")
		return false
	if dmg.has(300):
		tests._fail("enemy 300 not observable — damage should be omitted")
		return false
	var fx: Array = turn.get("applied_effects", []) as Array
	if fx.size() != 2:
		tests._fail("expected stun on100 (always) and 200 (visible via action)")
		return false
	var ids: Dictionary = {}
	for item in fx:
		var d: Dictionary = item as Dictionary
		ids[int(d.get("unit_id", 0))] = true
	if not ids.get(100, false) or not ids.get(200, false):
		tests._fail("applied_effects should include 100 and 200")
		return false
	if ids.get(400, false):
		tests._fail("effect on 400 should be filtered (not observable)")
		return false
	tests._pass("damage_by_id_and_effects_filtered")
	return true


static func _test_fov_cells_sorted(tests: Node) -> bool:
	tests._log("test_llm_planning_recent_turns: fov_cells_sorted")
	var ai_fov := {"1,0": true, "0,0": true, "1,1": false}
	var hist: Array = [{
		"turn": 3,
		"recording": {"died_ids": [], "actions": []},
		"ai_fov": ai_fov,
		"ai_unit_ids": [1],
	}]
	var out: Array = LlmPlanningRecentTurns.build_from_history(hist)
	var turn: Dictionary = out[0] as Dictionary
	if int(turn.get("turn", 0)) != 3:
		tests._fail("wrong turn")
		return false
	var cells: Array = turn.get("fov_cells", []) as Array
	if cells.size() != 2:
		tests._fail("expected two true fov cells, got %d" % cells.size())
		return false
	var c0: Array = cells[0] as Array
	var c1: Array = cells[1] as Array
	if int(c0[0]) != 0 or int(c0[1]) != 0:
		tests._fail("first cell should be [0,0]")
		return false
	if int(c1[0]) != 1 or int(c1[1]) != 0:
		tests._fail("second cell should be [1,0]")
		return false
	tests._pass("fov_cells_sorted")
	return true


static func _test_compact_action_includes_from_cell(tests: Node) -> bool:
	tests._log("test_llm_planning_recent_turns: compact_action_includes_from_cell")
	var hist: Array = [{
		"turn": 1,
		"recording": {
			"died_ids": [],
			"actions": [
				{"unit_id": 100, "unit_name": "MyUnit", "type": "ability", "action_key": "ranged_attack", "caster_cell": [2, 3], "end_point": [5, 5]},
				{"unit_id": 200, "unit_name": "Enemy", "type": "move", "from_cell": [1, 1], "path": [[1, 1], [2, 2]]},
			],
		},
		"ai_fov": {},
		"ai_unit_ids": [100],
	}]
	var out: Array = LlmPlanningRecentTurns.build_from_history(hist)
	var turn: Dictionary = out[0] as Dictionary
	var acts: Array = turn.get("actions", []) as Array
	if acts.size() != 2:
		tests._fail("expected 2 actions, got %d" % acts.size())
		return false
	var ability_act: Dictionary = acts[0] as Dictionary
	if not ability_act.has("from"):
		tests._fail("ability action should have 'from' field from caster_cell")
		return false
	var from_a: Array = ability_act.get("from", []) as Array
	if int(from_a[0]) != 2 or int(from_a[1]) != 3:
		tests._fail("ability from should be [2,3], got %s" % str(from_a))
		return false
	var end_a: Array = ability_act.get("end", []) as Array
	if int(end_a[0]) != 5 or int(end_a[1]) != 5:
		tests._fail("ability end should be [5,5] (target), got %s" % str(end_a))
		return false
	var move_act: Dictionary = acts[1] as Dictionary
	if not move_act.has("from"):
		tests._fail("move action should have 'from' field from from_cell")
		return false
	var from_m: Array = move_act.get("from", []) as Array
	if int(from_m[0]) != 1 or int(from_m[1]) != 1:
		tests._fail("move from should be [1,1], got %s" % str(from_m))
		return false
	tests._pass("compact_action_includes_from_cell")
	return true
