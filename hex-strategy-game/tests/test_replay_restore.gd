extends RefCounted
## Regression tests for replay restore when eliminated units were removed from scene.

const UnitsContainer = preload("res://src/battle/nodes/units/units.gd")

static func run_all(tests: Node) -> bool:
	var ok := true
	ok = _test_restore_before_state_recreates_missing_unit(tests) and ok
	ok = _test_replay_actions_resolve_unit_by_stable_id(tests) and ok
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
