extends RefCounted
## Regression tests for replay restore when eliminated units were removed from scene.

const UnitsContainer = preload("res://src/battle/nodes/units/units.gd")

static func run_all(tests: Node) -> bool:
	var ok := true
	ok = _test_restore_before_state_recreates_missing_unit(tests) and ok
	ok = _test_replay_actions_resolve_unit_by_stable_id(tests) and ok
	ok = _test_serialize_recording_actions_data_only(tests) and ok
	ok = _test_replay_actions_support_server_ac_dictionary(tests) and ok
	return ok

static func _make_container() -> UnitsContainer:
	var container := UnitsContainer.new()
	var player := Node2D.new()
	player.name = "player"
	container.add_child(player)
	var opponent := Node2D.new()
	opponent.name = "opponent"
	container.add_child(opponent)
	return container

static func _sample_before_state(unit_id: int, cell: Vector2) -> Dictionary:
	return {
		unit_id: {
			"unit_id": unit_id,
			"group_name": "opponent",
			"def_path": "res://src/unit/definitions/zergling.tres",
			"unit_name": "Zergling",
			"cell": cell,
			"health": 3,
			"max_health": 3,
			"max_energy": 0,
			"effects": [],
		}
	}

static func _test_restore_before_state_recreates_missing_unit(tests: Node) -> bool:
	tests._log("test_replay_restore: restore_before_state recreates eliminated units")
	var container := _make_container()
	tests.add_child(container)
	var target_cell := Vector2(2, -1)
	container._restore_before_state(_sample_before_state(5001, target_cell))
	var restored = container._find_unit_by_stable_id(5001)
	if restored == null:
		tests._fail("expected _restore_before_state to recreate missing unit")
		container.free()
		return false
	if not HexGrid.cell_equal(restored.cell, target_cell):
		tests._fail("restored unit cell should match before_state")
		container.free()
		return false
	if restored.health != 3:
		tests._fail("restored unit health should match before_state")
		container.free()
		return false
	tests._pass("restore_before_state recreates eliminated units")
	container.free()
	return true

static func _test_replay_actions_resolve_unit_by_stable_id(tests: Node) -> bool:
	tests._log("test_replay_restore: replay actions resolve using unit_id fallback")
	var container := _make_container()
	tests.add_child(container)
	var target_cell := Vector2(1, 0)
	container._restore_before_state(_sample_before_state(7001, target_cell))
	var recording_actions: Array = [{
		"type": "move",
		"unit_id": 7001,
		"unit": null,
		"path": [target_cell, Vector2(0, 0)],
	}]
	var actions_by_type: Dictionary = container._build_replay_actions_by_type(recording_actions)
	var move_entries: Array = actions_by_type.get("move", [])
	if move_entries.size() != 1:
		tests._fail("expected move replay entry to be built from unit_id fallback")
		container.free()
		return false
	var replay_unit = move_entries[0].get("unit")
	if replay_unit == null or int(replay_unit.get_meta("unit_id", 0)) != 7001:
		tests._fail("replay move entry should bind to restored unit by unit_id")
		container.free()
		return false
	tests._pass("replay actions resolve using unit_id fallback")
	container.free()
	return true

static func _test_serialize_recording_actions_data_only(tests: Node) -> bool:
	tests._log("test_replay_restore: recording actions serialize to data-only format")
	var container := _make_container()
	tests.add_child(container)
	container._restore_before_state(_sample_before_state(8001, Vector2(0, 0)))
	var unit = container._find_unit_by_stable_id(8001)
	if unit == null:
		tests._fail("expected fixture unit for serialization test")
		container.free()
		return false
	var defs: Array = Actions.get_ability_definitions_for_action("attack_short")
	if defs.is_empty():
		tests._fail("expected attack_short definitions to exist")
		container.free()
		return false
	var ac = defs[0].to_action_instance(unit)
	var raw_actions: Array = [{ "type": "ability", "unit": unit, "ac": ac }]
	var serialized: Array = container._serialize_recording_actions(raw_actions)
	if serialized.size() != 1:
		tests._fail("expected one serialized action")
		container.free()
		return false
	var entry: Dictionary = serialized[0]
	if entry.has("unit") or entry.has("ac"):
		tests._fail("serialized replay action should not contain runtime object references")
		container.free()
		return false
	if int(entry.get("unit_id", 0)) != 8001:
		tests._fail("serialized action should include stable unit_id")
		container.free()
		return false
	if str(entry.get("action_key", "")) != "attack_short":
		tests._fail("serialized action should keep action_key")
		container.free()
		return false
	if not entry.has("end_point"):
		tests._fail("serialized action should include end_point")
		container.free()
		return false
	tests._pass("recording actions serialize to data-only format")
	container.free()
	return true

static func _test_replay_actions_support_server_ac_dictionary(tests: Node) -> bool:
	tests._log("test_replay_restore: replay builder supports server-style dictionary ac payload")
	var container := _make_container()
	tests.add_child(container)
	container._restore_before_state(_sample_before_state(8101, Vector2(0, 0)))
	var recording_actions: Array = [{
		"type": "ability",
		"unit_id": 8101,
		"action_key": "attack_short",
		"ac": { "path": [[0, 0]], "end_point": [1, 0] }
	}]
	var actions_by_type: Dictionary = container._build_replay_actions_by_type(recording_actions)
	var ability_entries: Array = actions_by_type.get("ability", [])
	if ability_entries.size() != 1:
		tests._fail("expected one reconstructed ability entry")
		container.free()
		return false
	var ac = ability_entries[0].get("ac")
	if not (ac is ActionInstance):
		tests._fail("reconstructed entry should include ActionInstance")
		container.free()
		return false
	if ac.path.size() != 1 or not HexGrid.cell_equal(ac.path[0], Vector2(0, 0)):
		tests._fail("reconstructed ability path should come from dictionary ac.path")
		container.free()
		return false
	if not HexGrid.cell_equal(ac.end_point, Vector2(1, 0)):
		tests._fail("reconstructed ability end_point should come from dictionary ac.end_point")
		container.free()
		return false
	tests._pass("replay builder supports server-style dictionary ac payload")
	container.free()
	return true
