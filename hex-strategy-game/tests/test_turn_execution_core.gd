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
	ok = _test_get_damage_cells_self_or_adjacent_uses_absolute_endpoint(tests) and ok
	ok = _test_execute_turn_move_and_attack(tests) and ok
	ok = _test_execute_turn_move_does_not_deplete_tile_resource(tests) and ok
	ok = _test_execute_turn_extract_depletes_and_accumulates_group_resource(tests) and ok
	ok = _test_execute_turn_recruit_people_only_extracts_people(tests) and ok
	ok = _test_execute_turn_heal_adjacent_targets_absolute_cell(tests) and ok
	ok = _test_execute_turn_heal_and_incoming_damage_same_turn_maintains_health(tests) and ok
	ok = _test_execute_turn_spawn_scout_requires_people(tests) and ok
	ok = _test_execute_turn_scout_attack_ray_damages_only_target_tile(tests) and ok
	ok = _test_execute_turn_resupply_after_scout_attack_same_turn(tests) and ok
	ok = _test_execute_turn_attack_and_heal_same_phase_use_net_health(tests) and ok
	ok = _test_execute_turn_zergling_fast_move_hits_scout_before_scout_move(tests) and ok
	ok = _test_execute_turn_zergling_moves_onto_marine_attack_tile_takes_one_damage(tests) and ok
	ok = _test_check_win_condition_one_alive(tests) and ok
	ok = _test_check_win_condition_both_alive(tests) and ok
	ok = _test_check_win_condition_both_dead(tests) and ok
	ok = _test_stunned_unit_cannot_move(tests) and ok
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

static func _test_get_damage_cells_self_or_adjacent_uses_absolute_endpoint(tests: Node) -> bool:
	tests._log("test_turn_execution_core: get_damage_cells_for_config self_or_adjacent uses absolute end_point")
	var config := { "pattern": "self_or_adjacent" }
	var cells := TurnExecutionCore.get_damage_cells_for_config(3, 1, [], [4, 1], config)
	if cells.size() != 1:
		tests._fail("self_or_adjacent should return exactly one target cell, got %d" % cells.size())
		return false
	if cells[0] != Vector2i(4, 1):
		tests._fail("self_or_adjacent should use absolute end_point [4,1], got %s" % cells)
		return false
	tests._pass("get_damage_cells_for_config self_or_adjacent uses absolute end_point")
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

static func _test_execute_turn_recruit_people_only_extracts_people(tests: Node) -> bool:
	tests._log("test_turn_execution_core: recruit_people extracts only people resource")
	var target_key := HexGrid.get_cell_key(0, 0)
	var game_state := {
		"groups": [
			{ "name": "player", "ai": false, "units": [
				{ "unit_id": 1, "def_path": "res://src/unit/definitions/scout.tres", "cell": [0, 0], "health": 2, "max_health": 2, "energy": 3, "max_energy": 3 }
			]},
			{ "name": "opponent", "ai": false, "units": [] }
		],
		"tile_resources": {
			target_key: { "amount": 2, "max_amount": 2, "resource_type": "ore" }
		}
	}
	var player_actions := {
		"player": [
			{ "unit_id": 1, "action_key": "recruit_people", "path": [], "end_point": [0, 0] }
		],
		"opponent": []
	}
	TurnExecutionCore.execute_turn(game_state, player_actions)
	var ore_entry: Dictionary = game_state.get("tile_resources", {}).get(target_key, {})
	if int(ore_entry.get("amount", -1)) != 2:
		tests._fail("recruit_people should not deplete non-people resources")
		return false
	var inventory_after_ore: Dictionary = game_state.get("groups", [])[0].get("resources", {})
	if int(inventory_after_ore.get("people", 0)) != 0:
		tests._fail("recruit_people on ore should not add people resource")
		return false
	game_state["tile_resources"][target_key] = { "amount": 2, "max_amount": 2, "resource_type": "people" }
	TurnExecutionCore.execute_turn(game_state, player_actions)
	var people_entry: Dictionary = game_state.get("tile_resources", {}).get(target_key, {})
	if int(people_entry.get("amount", -1)) != 1:
		tests._fail("recruit_people should deplete people resource by 1")
		return false
	var inventory_after_people: Dictionary = game_state.get("groups", [])[0].get("resources", {})
	if int(inventory_after_people.get("people", 0)) != 1:
		tests._fail("recruit_people should add 1 people to group resources, got %s" % inventory_after_people)
		return false
	tests._pass("recruit_people extracts only people")
	return true

static func _test_execute_turn_heal_adjacent_targets_absolute_cell(tests: Node) -> bool:
	tests._log("test_turn_execution_core: heal_adjacent heals ally at absolute end_point cell")
	var game_state := {
		"groups": [
			{ "name": "player", "ai": false, "units": [
				{ "unit_id": 1, "def_path": "res://src/unit/definitions/medic.tres", "cell": [1, 0], "health": 2, "max_health": 2, "energy": 4, "max_energy": 4 },
				{ "unit_id": 2, "def_path": "res://src/unit/definitions/marine.tres", "cell": [2, 0], "health": 2, "max_health": 4, "energy": 0, "max_energy": 4 }
			]},
			{ "name": "opponent", "ai": false, "units": [] }
		]
	}
	var player_actions := {
		"player": [
			{ "unit_id": 1, "action_key": "heal_adjacent", "path": [], "end_point": [2, 0] }
		],
		"opponent": []
	}
	TurnExecutionCore.execute_turn(game_state, player_actions)
	var medic_found := TurnExecutionCore.find_unit_by_id(game_state, 1)
	if medic_found.is_empty():
		tests._fail("medic should still exist after healing")
		return false
	if int(medic_found.unit.get("energy", -1)) != 3:
		tests._fail("heal_adjacent should consume 1 medic energy (4 -> 3), got %s" % medic_found.unit.get("energy", -1))
		return false
	var marine_found := TurnExecutionCore.find_unit_by_id(game_state, 2)
	if marine_found.is_empty():
		tests._fail("marine should still exist after being healed")
		return false
	if int(marine_found.unit.get("health", 0)) != 3:
		tests._fail("heal_adjacent should heal marine at [2,0] by 1 (2 -> 3), got %s" % marine_found.unit.get("health", 0))
		return false
	tests._pass("heal_adjacent heals ally at absolute end_point cell")
	return true

static func _test_execute_turn_heal_and_incoming_damage_same_turn_maintains_health(tests: Node) -> bool:
	tests._log("test_turn_execution_core: marine health is maintained when healed and attacked in same turn")
	var game_state := {
		"groups": [
			{ "name": "player", "ai": false, "units": [
				{ "unit_id": 1, "def_path": "res://src/unit/definitions/medic.tres", "cell": [0, 0], "health": 2, "max_health": 2, "energy": 4, "max_energy": 4 },
				{ "unit_id": 2, "def_path": "res://src/unit/definitions/marine.tres", "cell": [1, 0], "health": 3, "max_health": 4, "energy": 4, "max_energy": 4 }
			]},
			{ "name": "opponent", "ai": true, "units": [
				{ "unit_id": 3, "def_path": "res://src/unit/definitions/viper.tres", "cell": [-1, 1], "health": 2, "max_health": 2, "energy": 0, "max_energy": 0 }
			]}
		]
	}
	var player_actions := {
		"player": [
			{ "unit_id": 1, "action_key": "heal_adjacent", "path": [], "end_point": [1, 0] },
		],
		"opponent": [
			{ "unit_id": 3, "action_key": "attack_viper", "path": [], "end_point": [1, 0] },
		]
	}
	TurnExecutionCore.execute_turn(game_state, player_actions)
	var marine_found := TurnExecutionCore.find_unit_by_id(game_state, 2)
	if marine_found.is_empty():
		tests._fail("marine should survive simultaneous heal/damage turn")
		return false
	if int(marine_found.unit.get("health", 0)) != 3:
		tests._fail("marine health should stay at 3 (heal +1 and damage -1), got %s" % marine_found.unit.get("health", 0))
		return false
	var medic_found := TurnExecutionCore.find_unit_by_id(game_state, 1)
	if medic_found.is_empty():
		tests._fail("medic should survive simultaneous heal/damage turn")
		return false
	if int(medic_found.unit.get("energy", -1)) != 3:
		tests._fail("medic should spend 1 energy for heal (4 -> 3), got %s" % medic_found.unit.get("energy", -1))
		return false
	tests._pass("marine health is maintained when healed and attacked in same turn")
	return true

static func _test_execute_turn_spawn_scout_requires_people(tests: Node) -> bool:
	tests._log("test_turn_execution_core: spawn_scout requires 5 people")
	var game_state := {
		"groups": [
			{ "name": "player", "ai": false, "resources": { "people": 4 }, "units": [
				{ "unit_id": 1, "def_path": "res://src/unit/definitions/terran_base.tres", "cell": [0, 0], "health": 6, "max_health": 6, "energy": 5, "max_energy": 5 }
			]},
			{ "name": "opponent", "ai": false, "units": [] }
		]
	}
	var player_actions := {
		"player": [
			{ "unit_id": 1, "action_key": "spawn_scout", "path": [], "end_point": [0, 0] }
		],
		"opponent": []
	}
	var blocked_recording := TurnExecutionCore.execute_turn(game_state, player_actions)
	if game_state.get("groups", [])[0].get("units", []).size() != 1:
		tests._fail("spawn_scout should not spawn when people < 5")
		return false
	if int(game_state.get("groups", [])[0].get("units", [])[0].get("energy", -1)) != 5:
		tests._fail("blocked spawn_scout should not consume energy")
		return false
	for a in blocked_recording.get("actions", []):
		if a.get("type", "") == "spawn":
			tests._fail("blocked spawn_scout should not record a spawn action")
			return false
	var groups_after_block: Array = game_state.get("groups", [])
	var player_group_after_block: Dictionary = groups_after_block[0]
	var player_resources_after_block: Dictionary = player_group_after_block.get("resources", {})
	player_resources_after_block["people"] = 5
	player_group_after_block["resources"] = player_resources_after_block
	groups_after_block[0] = player_group_after_block
	game_state["groups"] = groups_after_block
	var spawn_recording := TurnExecutionCore.execute_turn(game_state, player_actions)
	var units_after_spawn: Array = game_state.get("groups", [])[0].get("units", [])
	if units_after_spawn.size() != 2:
		tests._fail("spawn_scout should spawn a new scout when people >= 5")
		return false
	if units_after_spawn[1].get("def_path", "") != "res://src/unit/definitions/scout.tres":
		tests._fail("spawn_scout should create scout unit, got %s" % units_after_spawn[1].get("def_path", ""))
		return false
	if int(units_after_spawn[0].get("energy", -1)) != 0:
		tests._fail("successful spawn_scout should consume 5 energy")
		return false
	var has_spawn_record := false
	for a in spawn_recording.get("actions", []):
		if a.get("type", "") == "spawn" and a.get("action_key", "") == "spawn_scout":
			has_spawn_record = true
			break
	if not has_spawn_record:
		tests._fail("spawn_scout should record a spawn action")
		return false
	tests._pass("spawn_scout requires 5 people")
	return true

static func _test_execute_turn_scout_attack_ray_damages_only_target_tile(tests: Node) -> bool:
	tests._log("test_turn_execution_core: scout attack_ray damages only target tile")
	var game_state := {
		"groups": [
			{ "name": "player", "ai": false, "units": [
				{ "unit_id": 1, "def_path": "res://src/unit/definitions/scout.tres", "cell": [0, 0], "health": 2, "max_health": 2, "energy": 3, "max_energy": 3 }
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
	var scout := TurnExecutionCore.find_unit_by_id(game_state, 1)
	if scout.is_empty():
		tests._fail("scout should still exist after attacking")
		return false
	if int(scout.unit.get("energy", -1)) != 2:
		tests._fail("scout attack_ray should consume exactly 1 energy (3 -> 2), got %s" % scout.unit.get("energy", -1))
		return false
	tests._pass("scout attack_ray damages only target tile")
	return true

static func _test_execute_turn_resupply_after_scout_attack_same_turn(tests: Node) -> bool:
	tests._log("test_turn_execution_core: non-origin base resupplies scout after scout attacks same turn")
	# Base is not at origin. Action end_point is absolute world cell (as submitted by client).
	# Scout attacks (consumes 1), base resupplies scout (+1) in same turn => net 0 for scout energy.
	var game_state := {
		"groups": [
			{ "name": "player", "ai": false, "units": [
				{ "unit_id": 1, "def_path": "res://src/unit/definitions/terran_base.tres", "cell": [2, 1], "health": 6, "max_health": 6, "energy": 5, "max_energy": 5 },
				{ "unit_id": 2, "def_path": "res://src/unit/definitions/scout.tres", "cell": [3, 1], "health": 2, "max_health": 2, "energy": 3, "max_energy": 3 }
			]},
			{ "name": "opponent", "ai": false, "units": [
				{ "unit_id": 3, "def_path": "res://src/unit/definitions/zergling.tres", "cell": [5, 1], "health": 2, "max_health": 2, "energy": 0, "max_energy": 0 }
			]}
		]
	}
	# Order: resupply first, attack second - tests that support runs after attacks regardless of submission order
	var player_actions := {
		"player": [
			{ "unit_id": 1, "action_key": "resupply_adjacent", "path": [], "end_point": [3, 1] },
			{ "unit_id": 2, "action_key": "attack_ray", "path": [], "end_point": [5, 1] }
		],
		"opponent": []
	}
	TurnExecutionCore.execute_turn(game_state, player_actions)
	var scout := TurnExecutionCore.find_unit_by_id(game_state, 2)
	if scout.is_empty():
		tests._fail("scout should exist after turn")
		return false
	var scout_energy: int = int(scout.unit.get("energy", -1))
	if scout_energy != 3:
		tests._fail("non-origin resupply target should be absolute: scout should have 3 energy (attack 3->2, resupply +1 -> 3), got %d" % scout_energy)
		return false
	tests._pass("non-origin base resupplies scout after scout attacks same turn")
	return true

static func _test_execute_turn_attack_and_heal_same_phase_use_net_health(tests: Node) -> bool:
	tests._log("test_turn_execution_core: simultaneous attack and heal use net health")
	# Scout starts at 1 HP. Enemy marine attacks scout while allied base heals scout
	# in the same ability phase. Net delta should be 0, so scout remains at 1 HP.
	var game_state := {
		"groups": [
			{ "name": "player", "ai": false, "units": [
				{ "unit_id": 1, "def_path": "res://src/unit/definitions/terran_base.tres", "cell": [0, 0], "health": 6, "max_health": 6, "energy": 5, "max_energy": 5 },
				{ "unit_id": 2, "def_path": "res://src/unit/definitions/scout.tres", "cell": [1, 0], "health": 1, "max_health": 2, "energy": 3, "max_energy": 3 }
			]},
			{ "name": "opponent", "ai": false, "units": [
				{ "unit_id": 3, "def_path": "res://src/unit/definitions/marine.tres", "cell": [2, 0], "health": 3, "max_health": 3, "energy": 4, "max_energy": 4 }
			]}
		]
	}
	var player_actions := {
		"player": [
			{ "unit_id": 1, "action_key": "heal_adjacent", "path": [], "end_point": [1, 0] }
		],
		"opponent": [
			{ "unit_id": 3, "action_key": "attack_short", "path": [], "end_point": [1, 0] }
		]
	}
	TurnExecutionCore.execute_turn(game_state, player_actions)
	var scout := TurnExecutionCore.find_unit_by_id(game_state, 2)
	if scout.is_empty():
		tests._fail("scout should survive when same-phase heal offsets incoming damage")
		return false
	var scout_health: int = int(scout.unit.get("health", -1))
	if scout_health != 1:
		tests._fail("same-phase attack/heal should resolve by net health (expected 1, got %d)" % scout_health)
		return false
	tests._pass("simultaneous attack and heal use net health")
	return true

static func _test_execute_turn_zergling_fast_move_hits_scout_before_scout_move(tests: Node) -> bool:
	tests._log("test_turn_execution_core: zergling fast-move onto scout then scout moves takes one damage")
	var game_state := {
		"groups": [
			{ "name": "player", "ai": false, "units": [
				{ "unit_id": 1, "def_path": "res://src/unit/definitions/zergling.tres", "cell": [0, 0], "health": 1, "max_health": 1, "energy": 0, "max_energy": 0 }
			]},
			{ "name": "opponent", "ai": false, "units": [
				{ "unit_id": 2, "def_path": "res://src/unit/definitions/scout.tres", "cell": [1, 0], "health": 2, "max_health": 2, "energy": 3, "max_energy": 3 }
			]}
		]
	}
	var zerg_path: Array = []
	for p in HexGrid.build_path_to(0, 0, 1, 0):
		zerg_path.append([int(p.x), int(p.y)])
	var scout_path: Array = []
	for p in HexGrid.build_path_to(1, 0, 2, 0):
		scout_path.append([int(p.x), int(p.y)])
	var player_actions := {
		"player": [
			{ "unit_id": 1, "action_key": "fast_move", "path": zerg_path, "end_point": [1, 0] }
		],
		"opponent": [
			{ "unit_id": 2, "action_key": "move_short", "path": scout_path, "end_point": [2, 0] }
		]
	}
	var recording := TurnExecutionCore.execute_turn(game_state, player_actions)
	var scout_found := TurnExecutionCore.find_unit_by_id(game_state, 2)
	if scout_found.is_empty():
		tests._fail("scout should survive with 1 health after taking passive damage")
		return false
	var scout: Dictionary = scout_found.unit
	if scout.get("health", 0) != 1:
		tests._fail("scout should take exactly 1 damage, expected health 1 got %s" % scout.get("health", 0))
		return false
	if scout.get("cell", [0, 0]) != [2, 0]:
		tests._fail("scout should still complete move to [2,0], got %s" % scout.get("cell", []))
		return false
	if 2 in recording.get("died_ids", []):
		tests._fail("scout should not be in died_ids after taking one damage")
		return false
	tests._pass("zergling fast-move onto scout then scout moves takes one damage")
	return true

static func _test_execute_turn_zergling_moves_onto_marine_attack_tile_takes_one_damage(tests: Node) -> bool:
	tests._log("test_turn_execution_core: zergling moves onto tile marine attacks (marine not on tile) takes exactly 1 damage")
	# Marine at (1,0) attacks (2,0). Zergling at (0,0) fast-moves to (2,0). Zergling should take 1 damage from marine's attack_short, not 2.
	var game_state := {
		"groups": [
			{ "name": "player", "ai": false, "units": [
				{ "unit_id": 1, "def_path": "res://src/unit/definitions/marine.tres", "cell": [1, 0], "health": 3, "max_health": 3, "energy": 2, "max_energy": 4 }
			]},
			{ "name": "opponent", "ai": false, "units": [
				{ "unit_id": 2, "def_path": "res://src/unit/definitions/zergling.tres", "cell": [0, 0], "health": 3, "max_health": 3, "energy": 0, "max_energy": 0 }
			]}
		]
	}
	var zerg_path: Array = []
	for p in HexGrid.build_path_to(0, 0, 2, 0):
		zerg_path.append([int(p.x), int(p.y)])
	var player_actions := {
		"player": [
			{ "unit_id": 1, "action_key": "attack_short", "path": [], "end_point": [2, 0] }
		],
		"opponent": [
			{ "unit_id": 2, "action_key": "fast_move", "path": zerg_path, "end_point": [2, 0] }
		]
	}
	var recording := TurnExecutionCore.execute_turn(game_state, player_actions)
	var zerg_found := TurnExecutionCore.find_unit_by_id(game_state, 2)
	if zerg_found.is_empty():
		tests._fail("zergling should survive (3 hp - 1 dmg = 2)")
		return false
	var zerg: Dictionary = zerg_found.unit
	var zerg_health: int = zerg.get("health", 0)
	if zerg_health != 2:
		tests._fail("zergling should take exactly 1 damage (3 -> 2), got health %d" % zerg_health)
		return false
	tests._pass("zergling moves onto marine attack tile takes one damage")
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

## Regression: stunned unit is blocked for one turn, then stun expires.
static func _test_stunned_unit_cannot_move(tests: Node) -> bool:
	tests._log("test_turn_execution_core: stunned unit cannot move and stun expires after turn")
	var target_cell: Array = [1, 0]
	var move_path: Array = []
	for p in HexGrid.build_path_to(1, 0, 2, 0):
		move_path.append([int(p.x), int(p.y)])
	var game_state := {
		"groups": [
			{ "name": "player", "ai": false, "units": [
				{ "unit_id": 1, "def_path": "res://src/unit/definitions/marine.tres", "cell": [0, 0], "health": 3, "max_health": 3, "energy": 4, "max_energy": 4 }
			]},
			{ "name": "opponent", "ai": false, "units": [
				{ "unit_id": 2, "def_path": "res://src/unit/definitions/marine.tres", "cell": target_cell.duplicate(), "health": 3, "max_health": 3, "energy": 4, "max_energy": 4,
					"effects": [{ "kind": "Stun", "duration": 1, "params": {} }] }
			]}
		]
	}
	var player_actions := {
		"player": [],
		"opponent": [
			{ "unit_id": 2, "action_key": "move_short", "path": move_path, "end_point": [2, 0] }
		]
	}
	TurnExecutionCore.execute_turn(game_state, player_actions)
	var found := TurnExecutionCore.find_unit_by_id(game_state, 2)
	if found.is_empty():
		tests._fail("stunned unit should still exist")
		return false
	var cell_after: Array = found.unit.get("cell", [])
	if cell_after != target_cell:
		tests._fail("stunned unit must not move; expected cell %s, got %s" % [target_cell, cell_after])
		return false
	var effects_after_block: Array = found.unit.get("effects", [])
	if not effects_after_block.is_empty():
		tests._fail("stun should expire at end of the blocked turn, got effects %s" % effects_after_block)
		return false

	# Next turn: same move should now be allowed because stun expired.
	TurnExecutionCore.execute_turn(game_state, player_actions)
	var found_after_expire := TurnExecutionCore.find_unit_by_id(game_state, 2)
	if found_after_expire.is_empty():
		tests._fail("unit should still exist after stun expiration turn")
		return false
	var cell_after_expire: Array = found_after_expire.unit.get("cell", [])
	if cell_after_expire != [2, 0]:
		tests._fail("unit should move once stun expires; expected [2,0], got %s" % cell_after_expire)
		return false
	tests._pass("stunned unit cannot move and stun expires after turn")
	return true
