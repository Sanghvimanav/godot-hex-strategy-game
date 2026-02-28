extends RefCounted
## Tests for TurnExecutionCore: find_unit_by_id, get_units_at_cell, get_unit_def,
## get_damage_cells_for_config, execute_turn, check_win_condition.

const TurnExecutionCore = preload("res://src/battle/turn_execution_core.gd")

static func run_all(tests: Node) -> bool:
	var ok := true
	ok = _test_find_unit_by_id_found(tests) and ok
	ok = _test_find_unit_by_id_not_found(tests) and ok
	ok = _test_get_units_at_cell(tests) and ok
	ok = _test_get_units_at_cell_excludes_dead(tests) and ok
	ok = _test_get_unit_def(tests) and ok
	ok = _test_get_damage_cells_self(tests) and ok
	ok = _test_get_damage_cells_ray(tests) and ok
	ok = _test_get_damage_cells_target(tests) and ok
	ok = _test_get_damage_cells_area_adjacent(tests) and ok
	ok = _test_execute_turn_move_and_attack(tests) and ok
	ok = _test_execute_turn_move_does_not_deplete_tile_resource(tests) and ok
	ok = _test_execute_turn_extract_depletes_and_accumulates_group_resource(tests) and ok
	ok = _test_execute_turn_ghost_attack_ray_damages_only_target_tile(tests) and ok
	ok = _test_execute_turn_zergling_fast_move_hits_ghost_before_ghost_move(tests) and ok
	ok = _test_check_win_condition_one_alive(tests) and ok
	ok = _test_check_win_condition_both_alive(tests) and ok
	ok = _test_check_win_condition_both_dead(tests) and ok
	return ok

static func _test_find_unit_by_id_found(tests: Node) -> bool:
	tests._log("test_turn_execution_core: find_unit_by_id found")
	var game_state := {
		"groups": [
			{ "name": "player", "ai": false, "units": [
				{ "unit_id": 1, "def_path": "res://src/unit/definitions/marine.tres", "cell": [1, 0], "health": 2 }
			]},
			{ "name": "opponent", "ai": false, "units": [
				{ "unit_id": 2, "def_path": "res://src/unit/definitions/zergling.tres", "cell": [-1, 1], "health": 1 }
			]}
		]
	}
	var found := TurnExecutionCore.find_unit_by_id(game_state, 2)
	if found.is_empty():
		tests._fail("find_unit_by_id(2) should return unit and group")
		return false
	if found.unit.get("unit_id", -1) != 2:
		tests._fail("found unit should have unit_id 2")
		return false
	if found.group.get("name", "") != "opponent":
		tests._fail("found group should be opponent")
		return false
	tests._pass("find_unit_by_id found")
	return true

static func _test_find_unit_by_id_not_found(tests: Node) -> bool:
	tests._log("test_turn_execution_core: find_unit_by_id not found")
	var game_state := {
		"groups": [{ "name": "player", "ai": false, "units": [{ "unit_id": 1, "cell": [0, 0] }] }]
	}
	var found := TurnExecutionCore.find_unit_by_id(game_state, 999)
	if not found.is_empty():
		tests._fail("find_unit_by_id(999) should return empty")
		return false
	tests._pass("find_unit_by_id not found")
	return true

static func _test_get_units_at_cell(tests: Node) -> bool:
	tests._log("test_turn_execution_core: get_units_at_cell")
	var game_state := {
		"groups": [
			{ "name": "player", "ai": false, "units": [
				{ "unit_id": 1, "cell": [2, 0], "health": 2 }
			]},
			{ "name": "opponent", "ai": false, "units": [
				{ "unit_id": 2, "cell": [2, 0], "health": 1 }
			]}
		]
	}
	var units := TurnExecutionCore.get_units_at_cell(game_state, Vector2i(2, 0))
	if units.size() != 2:
		tests._fail("get_units_at_cell should return 2 units at (2,0), got %d" % units.size())
		return false
	tests._pass("get_units_at_cell")
	return true

static func _test_get_units_at_cell_excludes_dead(tests: Node) -> bool:
	tests._log("test_turn_execution_core: get_units_at_cell excludes dead")
	var game_state := {
		"groups": [
			{ "name": "player", "ai": false, "units": [
				{ "unit_id": 1, "cell": [2, 0], "health": 0 }
			]}
		]
	}
	var units := TurnExecutionCore.get_units_at_cell(game_state, Vector2i(2, 0))
	if units.size() != 0:
		tests._fail("get_units_at_cell should exclude dead units, got %d" % units.size())
		return false
	tests._pass("get_units_at_cell excludes dead")
	return true

static func _test_get_unit_def(tests: Node) -> bool:
	tests._log("test_turn_execution_core: get_unit_def")
	var def := TurnExecutionCore.get_unit_def("res://src/unit/definitions/marine.tres")
	if def.is_empty():
		tests._fail("get_unit_def should return dict for marine")
		return false
	if not def.has("move_action_keys"):
		tests._fail("get_unit_def should have move_action_keys")
		return false
	if not def.has("ability_action_keys"):
		tests._fail("get_unit_def should have ability_action_keys")
		return false
	if not def.has("passive_action_keys"):
		tests._fail("get_unit_def should have passive_action_keys")
		return false
	if def.get("max_health", 0) < 1:
		tests._fail("get_unit_def should have max_health")
		return false
	tests._pass("get_unit_def")
	return true

static func _test_get_damage_cells_self(tests: Node) -> bool:
	tests._log("test_turn_execution_core: get_damage_cells_for_config self")
	var config := { "pattern": "self" }
	var cells := TurnExecutionCore.get_damage_cells_for_config(3, -1, [], [0, 0], config)
	if cells.size() != 1:
		tests._fail("self pattern should return 1 cell, got %d" % cells.size())
		return false
	if cells[0] != Vector2i(3, -1):
		tests._fail("self pattern should return attacker cell, got %s" % cells)
		return false
	tests._pass("get_damage_cells_for_config self")
	return true

static func _test_get_damage_cells_ray(tests: Node) -> bool:
	tests._log("test_turn_execution_core: get_damage_cells_for_config ray")
	var config := { "pattern": "ray" }
	var cells := TurnExecutionCore.get_damage_cells_for_config(0, 0, [], [2, 0], config)
	if cells.size() < 2:
		tests._fail("ray pattern should return path to target, got %d cells" % cells.size())
		return false
	if not HexGrid.cell_equal(cells[cells.size() - 1], Vector2(2, 0)):
		tests._fail("ray last cell should be end_point")
		return false
	tests._pass("get_damage_cells_for_config ray")
	return true

static func _test_get_damage_cells_target(tests: Node) -> bool:
	tests._log("test_turn_execution_core: get_damage_cells_for_config target")
	var config := { "pattern": "target" }
	var cells := TurnExecutionCore.get_damage_cells_for_config(0, 0, [], [2, 1], config)
	if cells.size() != 1:
		tests._fail("target pattern should return 1 cell, got %d" % cells.size())
		return false
	if cells[0] != Vector2i(2, 1):
		tests._fail("target pattern should return end_point, got %s" % cells)
		return false
	tests._pass("get_damage_cells_for_config target")
	return true

static func _test_get_damage_cells_area_adjacent(tests: Node) -> bool:
	tests._log("test_turn_execution_core: get_damage_cells_for_config area_adjacent")
	var config := { "pattern": "area_adjacent" }
	var cells := TurnExecutionCore.get_damage_cells_for_config(0, 0, [], [0, 0], config)
	if cells.size() < 2:
		tests._fail("area_adjacent should return self + adjacent, got %d" % cells.size())
		return false
	var has_self := false
	for c in cells:
		if c == Vector2i(0, 0):
			has_self = true
			break
	if not has_self:
		tests._fail("area_adjacent should include attacker cell")
		return false
	tests._pass("get_damage_cells_for_config area_adjacent")
	return true

static func _test_execute_turn_move_and_attack(tests: Node) -> bool:
	tests._log("test_turn_execution_core: execute_turn move and attack")
	var game_state := {
		"groups": [
			{ "name": "player", "ai": false, "units": [
				{ "unit_id": 1, "def_path": "res://src/unit/definitions/marine.tres", "cell": [1, 0], "health": 3, "max_health": 3, "energy": 2, "max_energy": 4 }
			]},
			{ "name": "opponent", "ai": false, "units": [
				{ "unit_id": 2, "def_path": "res://src/unit/definitions/zergling.tres", "cell": [0, 0], "health": 1, "max_health": 1, "energy": 0, "max_energy": 0 }
			]}
		]
	}
	var player_actions := {
		"player": [
			{ "unit_id": 1, "action_key": "attack_short", "path": [], "end_point": [0, 0] }
		],
		"opponent": []
	}
	var recording := TurnExecutionCore.execute_turn(game_state, player_actions)
	if not recording.has("actions"):
		tests._fail("recording should have actions")
		return false
	if not recording.has("died_ids"):
		tests._fail("recording should have died_ids")
		return false
	var move_count := 0
	var ability_count := 0
	for a in recording.actions:
		if a.get("type", "") == "move":
			move_count += 1
		elif a.get("type", "") in ["fast ability", "ability", "slow ability"]:
			ability_count += 1
	if ability_count < 1:
		tests._fail("recording should have at least one ability action")
		return false
	if 2 not in recording.died_ids:
		tests._fail("zergling (unit 2) should be in died_ids after attack")
		return false
	var opponent_units: Array = game_state["groups"][1]["units"]
	if opponent_units.size() != 0:
		tests._fail("opponent should have 0 units after zergling dies, got %d" % opponent_units.size())
		return false
	tests._pass("execute_turn move and attack")
	return true

static func _test_execute_turn_move_does_not_deplete_tile_resource(tests: Node) -> bool:
	tests._log("test_turn_execution_core: move does not deplete tile resource")
	var target_key := HexGrid.get_cell_key(1, 0)
	var game_state := {
		"groups": [
			{ "name": "player", "ai": false, "units": [
				{ "unit_id": 1, "def_path": "res://src/unit/definitions/marine.tres", "cell": [0, 0], "health": 3, "max_health": 3, "energy": 2, "max_energy": 4 }
			]},
			{ "name": "opponent", "ai": false, "units": [] }
		],
		"tile_resources": {
			target_key: { "amount": 2, "max_amount": 2, "resource_type": "ore" }
		}
	}
	var move_path: Array = []
	for p in HexGrid.build_path_to(0, 0, 1, 0):
		move_path.append([int(p.x), int(p.y)])
	var player_actions := {
		"player": [
			{ "unit_id": 1, "action_key": "move_short", "path": move_path, "end_point": [1, 0] }
		],
		"opponent": []
	}
	TurnExecutionCore.execute_turn(game_state, player_actions)
	var resources: Dictionary = game_state.get("tile_resources", {})
	var entry: Dictionary = resources.get(target_key, {})
	if int(entry.get("amount", -1)) != 2:
		tests._fail("moving onto resource tile should not deplete it; expected amount 2 got %s" % entry)
		return false
	tests._pass("move does not deplete tile resource")
	return true

static func _test_execute_turn_extract_depletes_and_accumulates_group_resource(tests: Node) -> bool:
	tests._log("test_turn_execution_core: extract depletes tile and adds to group resources")
	var target_key := HexGrid.get_cell_key(0, 0)
	var game_state := {
		"groups": [
			{ "name": "player", "ai": false, "units": [
				{ "unit_id": 1, "def_path": "res://src/unit/definitions/knight.tres", "cell": [0, 0], "health": 3, "max_health": 3, "energy": 2, "max_energy": 4 }
			]},
			{ "name": "opponent", "ai": false, "units": [] }
		],
		"tile_resources": {
			target_key: { "amount": 1, "max_amount": 1, "resource_type": "ore" }
		}
	}
	var player_actions := {
		"player": [
			{ "unit_id": 1, "action_key": "extract_tile", "path": [], "end_point": [0, 0] }
		],
		"opponent": []
	}
	TurnExecutionCore.execute_turn(game_state, player_actions)
	var resources: Dictionary = game_state.get("tile_resources", {})
	var entry: Dictionary = resources.get(target_key, {})
	if int(entry.get("amount", -1)) != 0:
		tests._fail("extract_tile should deplete amount to 0, got %s" % entry)
		return false
	var player_group: Dictionary = game_state.get("groups", [])[0]
	var inventory: Dictionary = player_group.get("resources", {})
	if int(inventory.get("ore", 0)) != 1:
		tests._fail("extract_tile should add 1 ore to player resources, got %s" % inventory)
		return false
	tests._pass("extract depletes tile and adds to group resources")
	return true

static func _test_execute_turn_ghost_attack_ray_damages_only_target_tile(tests: Node) -> bool:
	tests._log("test_turn_execution_core: ghost attack_ray damages only target tile")
	var game_state := {
		"groups": [
			{ "name": "player", "ai": false, "units": [
				{ "unit_id": 1, "def_path": "res://src/unit/definitions/ghost.tres", "cell": [0, 0], "health": 2, "max_health": 2, "energy": 3, "max_energy": 3 }
			]},
			{ "name": "opponent", "ai": false, "units": [
				{ "unit_id": 2, "def_path": "res://src/unit/definitions/marine.tres", "cell": [1, 0], "health": 3, "max_health": 3, "energy": 4, "max_energy": 4 },
				{ "unit_id": 3, "def_path": "res://src/unit/definitions/marine.tres", "cell": [2, 0], "health": 3, "max_health": 3, "energy": 4, "max_energy": 4 }
			]}
		]
	}
	var player_actions := {
		"player": [
			{ "unit_id": 1, "action_key": "attack_ray", "path": [], "end_point": [2, 0] }
		],
		"opponent": []
	}
	TurnExecutionCore.execute_turn(game_state, player_actions)
	var near_enemy := TurnExecutionCore.find_unit_by_id(game_state, 2)
	if near_enemy.is_empty():
		tests._fail("intermediate enemy should still be alive")
		return false
	if near_enemy.unit.get("health", 0) != 3:
		tests._fail("intermediate enemy at [1,0] should take no damage, got health %s" % near_enemy.unit.get("health", 0))
		return false
	var target_enemy := TurnExecutionCore.find_unit_by_id(game_state, 3)
	if target_enemy.is_empty():
		tests._fail("target enemy should still be alive with reduced health")
		return false
	if target_enemy.unit.get("health", 0) != 2:
		tests._fail("target enemy at [2,0] should take exactly 1 damage, got health %s" % target_enemy.unit.get("health", 0))
		return false
	tests._pass("ghost attack_ray damages only target tile")
	return true

static func _test_execute_turn_zergling_fast_move_hits_ghost_before_ghost_move(tests: Node) -> bool:
	tests._log("test_turn_execution_core: zergling fast-move onto ghost then ghost moves takes one damage")
	var game_state := {
		"groups": [
			{ "name": "player", "ai": false, "units": [
				{ "unit_id": 1, "def_path": "res://src/unit/definitions/zergling.tres", "cell": [0, 0], "health": 1, "max_health": 1, "energy": 0, "max_energy": 0 }
			]},
			{ "name": "opponent", "ai": false, "units": [
				{ "unit_id": 2, "def_path": "res://src/unit/definitions/ghost.tres", "cell": [1, 0], "health": 2, "max_health": 2, "energy": 3, "max_energy": 3 }
			]}
		]
	}
	var zerg_path: Array = []
	for p in HexGrid.build_path_to(0, 0, 1, 0):
		zerg_path.append([int(p.x), int(p.y)])
	var ghost_path: Array = []
	for p in HexGrid.build_path_to(1, 0, 2, 0):
		ghost_path.append([int(p.x), int(p.y)])
	var player_actions := {
		"player": [
			{ "unit_id": 1, "action_key": "fast_move", "path": zerg_path, "end_point": [1, 0] }
		],
		"opponent": [
			{ "unit_id": 2, "action_key": "move_short", "path": ghost_path, "end_point": [2, 0] }
		]
	}
	var recording := TurnExecutionCore.execute_turn(game_state, player_actions)
	var ghost_found := TurnExecutionCore.find_unit_by_id(game_state, 2)
	if ghost_found.is_empty():
		tests._fail("ghost should survive with 1 health after taking passive damage")
		return false
	var ghost: Dictionary = ghost_found.unit
	if ghost.get("health", 0) != 1:
		tests._fail("ghost should take exactly 1 damage, expected health 1 got %s" % ghost.get("health", 0))
		return false
	if ghost.get("cell", [0, 0]) != [2, 0]:
		tests._fail("ghost should still complete move to [2,0], got %s" % ghost.get("cell", []))
		return false
	if 2 in recording.get("died_ids", []):
		tests._fail("ghost should not be in died_ids after taking one damage")
		return false
	tests._pass("zergling fast-move onto ghost then ghost moves takes one damage")
	return true

static func _test_check_win_condition_one_alive(tests: Node) -> bool:
	tests._log("test_turn_execution_core: check_win_condition one alive")
	var game_state := {
		"groups": [
			{ "name": "player", "ai": false, "units": [{ "unit_id": 1, "health": 2 }] },
			{ "name": "opponent", "ai": false, "units": [] }
		]
	}
	var winner := TurnExecutionCore.check_win_condition(game_state)
	if winner != "player":
		tests._fail("check_win_condition should return player when only player alive, got %s" % winner)
		return false
	tests._pass("check_win_condition one alive")
	return true

static func _test_check_win_condition_both_alive(tests: Node) -> bool:
	tests._log("test_turn_execution_core: check_win_condition both alive")
	var game_state := {
		"groups": [
			{ "name": "player", "ai": false, "units": [{ "unit_id": 1, "health": 2 }] },
			{ "name": "opponent", "ai": false, "units": [{ "unit_id": 2, "health": 1 }] }
		]
	}
	var winner := TurnExecutionCore.check_win_condition(game_state)
	if winner != "":
		tests._fail("check_win_condition should return empty when both alive, got %s" % winner)
		return false
	tests._pass("check_win_condition both alive")
	return true

static func _test_check_win_condition_both_dead(tests: Node) -> bool:
	tests._log("test_turn_execution_core: check_win_condition both dead")
	var game_state := {
		"groups": [
			{ "name": "player", "ai": false, "units": [] },
			{ "name": "opponent", "ai": false, "units": [] }
		]
	}
	var winner := TurnExecutionCore.check_win_condition(game_state)
	if winner != "":
		tests._fail("check_win_condition should return empty when both dead, got %s" % winner)
		return false
	tests._pass("check_win_condition both dead")
	return true
