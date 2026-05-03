extends RefCounted
## Tests that SP and MP share the same rule source: TurnExecutionCore and TurnExecutor
## use consistent damage logic (get_damage_cells matches get_damage_cells_for_config).

const TurnExecutionCore = preload("res://src/battle/turn_execution_core.gd")
const TurnExecutor = preload("res://src/battle/turn_executor.gd")
const ActionInstance = preload("res://src/unit/action_collection.gd")

static func run_all(tests: Node) -> bool:
	var ok := true
	ok = _test_damage_cells_self_matches(tests) and ok
	ok = _test_damage_cells_ray_matches(tests) and ok
	ok = _test_damage_cells_target_matches(tests) and ok
	ok = _test_execute_turn_recording_structure(tests) and ok
	return ok

static func _test_damage_cells_self_matches(tests: Node) -> bool:
	tests._log("test_unified_pipeline: TurnExecutor.get_damage_cells matches core for self")
	var ac := ActionInstance.new(null, null)
	ac.path = []
	ac.end_point = Vector2(0, 0)
	var config := { "pattern": "self" }
	var attacker_cell := Vector2(3, -1)
	var core_cells := TurnExecutionCore.get_damage_cells_for_config(3, -1, [], [0, 0], config)
	var exec_cells := TurnExecutor.get_damage_cells(attacker_cell, ac, config)
	if core_cells.size() != exec_cells.size():
		tests._fail("self: core and executor should return same count, core=%d exec=%d" % [core_cells.size(), exec_cells.size()])
		return false
	for i in core_cells.size():
		if not HexGrid.cell_equal(core_cells[i], exec_cells[i]):
			tests._fail("self: cell %d should match" % i)
			return false
	tests._pass("TurnExecutor.get_damage_cells matches core for self")
	return true

static func _test_damage_cells_ray_matches(tests: Node) -> bool:
	tests._log("test_unified_pipeline: TurnExecutor.get_damage_cells matches core for ray")
	var ac := ActionInstance.new(null, null)
	ac.path = [Vector2(1, 0)]
	ac.end_point = Vector2(2, 0)
	var config := { "pattern": "ray" }
	var core_cells := TurnExecutionCore.get_damage_cells_for_config(0, 0, ac.path, ac.end_point, config)
	var exec_cells := TurnExecutor.get_damage_cells(Vector2(0, 0), ac, config)
	if core_cells.size() != exec_cells.size():
		tests._fail("ray: core and executor should return same count, core=%d exec=%d" % [core_cells.size(), exec_cells.size()])
		return false
	for i in core_cells.size():
		if not HexGrid.cell_equal(core_cells[i], exec_cells[i]):
			tests._fail("ray: cell %d should match" % i)
			return false
	tests._pass("TurnExecutor.get_damage_cells matches core for ray")
	return true

static func _test_damage_cells_target_matches(tests: Node) -> bool:
	tests._log("test_unified_pipeline: TurnExecutor.get_damage_cells matches core for target")
	var ac := ActionInstance.new(null, null)
	ac.path = [Vector2(1, 0)]
	ac.end_point = Vector2(2, 0)
	var config := { "pattern": "target" }
	var core_cells := TurnExecutionCore.get_damage_cells_for_config(0, 0, ac.path, ac.end_point, config)
	var exec_cells := TurnExecutor.get_damage_cells(Vector2(0, 0), ac, config)
	if core_cells.size() != exec_cells.size():
		tests._fail("target: core and executor should return same count")
		return false
	for i in core_cells.size():
		if not HexGrid.cell_equal(core_cells[i], exec_cells[i]):
			tests._fail("target: cell %d should match" % i)
			return false
	tests._pass("TurnExecutor.get_damage_cells matches core for target")
	return true

static func _test_execute_turn_recording_structure(tests: Node) -> bool:
	tests._log("test_unified_pipeline: execute_turn produces valid recording structure")
	var game_state := {
		"groups": [
			{ "name": "terran", "ai": false, "units": [
				{ "unit_id": 1, "def_path": "res://src/unit/definitions/zergling.tres", "cell": [0, 0], "health": 1, "max_health": 1, "energy": 0, "max_energy": 0 }
			]},
			{ "name": "zerg", "ai": false, "units": [
				{ "unit_id": 2, "def_path": "res://src/unit/definitions/marine.tres", "cell": [1, 0], "health": 2, "max_health": 3, "energy": 0, "max_energy": 0 }
			]}
		]
	}
	var player_actions := {
		"terran": [
			{ "unit_id": 1, "action_key": "fast_move", "path": [[1, 0]], "end_point": [1, 0] }
		],
		"zerg": []
	}
	var recording := TurnExecutionCore.execute_turn(game_state, player_actions)
	if not recording.has("actions"):
		tests._fail("recording should have actions")
		return false
	if not recording.has("died_ids"):
		tests._fail("recording should have died_ids")
		return false
	var has_move := false
	var has_ability := false
	for a in recording.actions:
		if a.get("type", "") == "move":
			has_move = true
		elif str(a.get("type", "")) in ["fast ability", "ability", "slow ability"]:
			has_ability = true
	if not has_move:
		tests._fail("recording should have move action")
		return false
	if not has_ability:
		tests._fail("recording should have ability action (passive)")
		return false
	tests._pass("execute_turn produces valid recording structure")
	return true
