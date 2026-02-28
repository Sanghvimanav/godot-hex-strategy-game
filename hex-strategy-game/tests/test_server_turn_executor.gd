extends RefCounted
## Tests for ServerTurnExecutor: validate_action, execute_turn delegation.

const ServerTurnExecutor = preload("res://src/server/server_turn_executor.gd")
const TurnExecutionCore = preload("res://src/battle/turn_execution_core.gd")

static func run_all(tests: Node) -> bool:
	var ok := true
	ok = _test_validate_action_valid_move(tests) and ok
	ok = _test_validate_action_invalid_path(tests) and ok
	ok = _test_validate_action_unit_not_found(tests) and ok
	ok = _test_validate_action_dead_unit(tests) and ok
	ok = _test_validate_action_target_out_of_range(tests) and ok
	ok = _test_validate_action_ghost_attack_ray_range_window(tests) and ok
	ok = _test_validate_action_extract_requires_resource(tests) and ok
	ok = _test_execute_turn_delegates_to_core(tests) and ok
	return ok

static func _make_game_state() -> Dictionary:
	return {
		"groups": [
			{ "name": "player", "ai": false, "units": [
				{ "unit_id": 1, "def_path": "res://src/unit/definitions/marine.tres", "cell": [1, 0], "health": 3, "max_health": 3, "energy": 2, "max_energy": 4 }
			]},
			{ "name": "opponent", "ai": false, "units": [
				{ "unit_id": 2, "def_path": "res://src/unit/definitions/zergling.tres", "cell": [-1, 1], "health": 1, "max_health": 1, "energy": 0, "max_energy": 0 }
			]}
		]
	}

static func _make_ghost_game_state() -> Dictionary:
	return {
		"groups": [
			{ "name": "player", "ai": false, "units": [
				{ "unit_id": 1, "def_path": "res://src/unit/definitions/ghost.tres", "cell": [0, 0], "health": 2, "max_health": 2, "energy": 3, "max_energy": 3 }
			]},
			{ "name": "opponent", "ai": false, "units": [
				{ "unit_id": 2, "def_path": "res://src/unit/definitions/marine.tres", "cell": [3, 0], "health": 3, "max_health": 3, "energy": 4, "max_energy": 4 }
			]}
		]
	}

static func _test_validate_action_valid_move(tests: Node) -> bool:
	tests._log("test_server_turn_executor: validate_action valid move")
	var game_state := _make_game_state()
	var expected_path := HexGrid.build_path_to(1, 0, 2, 0)
	var path_arr: Array = []
	for p in expected_path:
		path_arr.append([int(p.x), int(p.y)])
	var action := {
		"unit_id": 1,
		"action_key": "move_short",
		"path": path_arr,
		"end_point": [2, 0]
	}
	var result := ServerTurnExecutor.validate_action(game_state, action, "player")
	if not result.get("valid", false):
		tests._fail("valid move should pass validation: %s" % result.get("error", ""))
		return false
	tests._pass("validate_action valid move")
	return true

static func _test_validate_action_invalid_path(tests: Node) -> bool:
	tests._log("test_server_turn_executor: validate_action invalid path")
	var game_state := _make_game_state()
	var action := {
		"unit_id": 1,
		"action_key": "move_short",
		"path": [[99, 99]],
		"end_point": [2, 0]
	}
	var result := ServerTurnExecutor.validate_action(game_state, action, "player")
	if result.get("valid", false):
		tests._fail("invalid path should fail validation")
		return false
	if "Invalid path" not in str(result.get("error", "")):
		tests._fail("invalid path should return Invalid path error, got %s" % result.get("error", ""))
		return false
	tests._pass("validate_action invalid path")
	return true

static func _test_validate_action_unit_not_found(tests: Node) -> bool:
	tests._log("test_server_turn_executor: validate_action unit not found")
	var game_state := _make_game_state()
	var action := {
		"unit_id": 999,
		"action_key": "move_short",
		"path": [],
		"end_point": [2, 0]
	}
	var result := ServerTurnExecutor.validate_action(game_state, action, "player")
	if result.get("valid", false):
		tests._fail("unit not found should fail validation")
		return false
	if "Unit not found" not in str(result.get("error", "")):
		tests._fail("unit not found should return Unit not found error, got %s" % result.get("error", ""))
		return false
	tests._pass("validate_action unit not found")
	return true

static func _test_validate_action_dead_unit(tests: Node) -> bool:
	tests._log("test_server_turn_executor: validate_action dead unit")
	var game_state := _make_game_state()
	game_state["groups"][0]["units"][0]["health"] = 0
	var action := {
		"unit_id": 1,
		"action_key": "move_short",
		"path": [],
		"end_point": [2, 0]
	}
	var result := ServerTurnExecutor.validate_action(game_state, action, "player")
	if result.get("valid", false):
		tests._fail("dead unit should fail validation")
		return false
	if "dead" not in str(result.get("error", "")).to_lower():
		tests._fail("dead unit should return dead-related error, got %s" % result.get("error", ""))
		return false
	tests._pass("validate_action dead unit")
	return true

static func _test_validate_action_target_out_of_range(tests: Node) -> bool:
	tests._log("test_server_turn_executor: validate_action target out of range")
	var game_state := _make_game_state()
	var action := {
		"unit_id": 1,
		"action_key": "attack_short",
		"path": [],
		"end_point": [10, 10]
	}
	var result := ServerTurnExecutor.validate_action(game_state, action, "player")
	if result.get("valid", false):
		tests._fail("target out of range should fail validation")
		return false
	if "range" not in str(result.get("error", "")).to_lower():
		tests._fail("out of range should return range-related error, got %s" % result.get("error", ""))
		return false
	tests._pass("validate_action target out of range")
	return true

static func _test_validate_action_ghost_attack_ray_range_window(tests: Node) -> bool:
	tests._log("test_server_turn_executor: validate_action ghost attack_ray range window (2-3)")
	var game_state := _make_ghost_game_state()

	var too_close := {
		"unit_id": 1,
		"action_key": "attack_ray",
		"path": [],
		"end_point": [1, 0]
	}
	var too_close_result := ServerTurnExecutor.validate_action(game_state, too_close, "player")
	if too_close_result.get("valid", false):
		tests._fail("ghost attack_ray at distance 1 should fail validation")
		return false

	var valid := {
		"unit_id": 1,
		"action_key": "attack_ray",
		"path": [],
		"end_point": [3, 0]
	}
	var valid_result := ServerTurnExecutor.validate_action(game_state, valid, "player")
	if not valid_result.get("valid", false):
		tests._fail("ghost attack_ray at distance 3 should pass validation: %s" % valid_result.get("error", ""))
		return false

	var too_far := {
		"unit_id": 1,
		"action_key": "attack_ray",
		"path": [],
		"end_point": [4, 0]
	}
	var too_far_result := ServerTurnExecutor.validate_action(game_state, too_far, "player")
	if too_far_result.get("valid", false):
		tests._fail("ghost attack_ray at distance 4 should fail validation")
		return false
	tests._pass("validate_action ghost attack_ray range window (2-3)")
	return true

static func _test_validate_action_extract_requires_resource(tests: Node) -> bool:
	tests._log("test_server_turn_executor: validate_action extract requires resource on unit tile")
	var game_state := {
		"groups": [
			{ "name": "player", "ai": false, "units": [
				{ "unit_id": 1, "def_path": "res://src/unit/definitions/knight.tres", "cell": [0, 0], "health": 3, "max_health": 3, "energy": 0, "max_energy": 0 }
			]},
			{ "name": "opponent", "ai": false, "units": [] }
		],
		"tile_resources": {}
	}
	var extract_action := {
		"unit_id": 1,
		"action_key": "extract_tile",
		"path": [],
		"end_point": [0, 0]
	}
	var fail_result := ServerTurnExecutor.validate_action(game_state, extract_action, "player")
	if fail_result.get("valid", false):
		tests._fail("extract should fail when tile has no resource")
		return false
	game_state["tile_resources"] = {
		HexGrid.get_cell_key(0, 0): { "amount": 1, "max_amount": 1, "resource_type": "ore" }
	}
	var ok_result := ServerTurnExecutor.validate_action(game_state, extract_action, "player")
	if not ok_result.get("valid", false):
		tests._fail("extract should pass when tile has resource: %s" % ok_result.get("error", ""))
		return false
	tests._pass("validate_action extract requires resource")
	return true

static func _test_execute_turn_delegates_to_core(tests: Node) -> bool:
	tests._log("test_server_turn_executor: execute_turn delegates to core")
	var game_state := _make_game_state()
	var player_actions := {
		"player": [{ "unit_id": 1, "action_key": "attack_short", "path": [], "end_point": [0, 0] }],
		"opponent": []
	}
	var core_result := TurnExecutionCore.execute_turn(game_state.duplicate(true), player_actions.duplicate(true))
	var server_result := ServerTurnExecutor.execute_turn(game_state.duplicate(true), player_actions.duplicate(true))
	if core_result.died_ids != server_result.died_ids:
		tests._fail("ServerTurnExecutor.execute_turn should match TurnExecutionCore died_ids")
		return false
	if core_result.actions.size() != server_result.actions.size():
		tests._fail("ServerTurnExecutor.execute_turn should match TurnExecutionCore actions size")
		return false
	tests._pass("execute_turn delegates to core")
	return true
