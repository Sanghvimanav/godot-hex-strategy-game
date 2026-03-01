extends RefCounted
## Regression tests for replay restore when eliminated units were removed from scene.

const UnitsContainer = preload("res://src/battle/nodes/units/units.gd")

static func run_all(tests: Node) -> bool:
	var ok := true
	ok = _test_restore_before_state_recreates_missing_unit(tests) and ok
	ok = _test_replay_actions_resolve_unit_by_stable_id(tests) and ok
	ok = _test_serialize_recording_actions_data_only(tests) and ok
	ok = _test_replay_actions_support_server_ac_dictionary(tests) and ok
	ok = _test_replay_history_stores_multiple_turns(tests) and ok
	ok = _test_replay_history_respects_capacity(tests) and ok
	ok = _test_apply_scenario_uses_health_and_energy_overrides(tests) and ok
	ok = _test_replay_summary_panel_hides_after_replay_finished(tests) and ok
	ok = _test_replay_summary_lines_group_by_phase_and_mark_cancelled(tests) and ok
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

static func _test_replay_history_stores_multiple_turns(tests: Node) -> bool:
	tests._log("test_replay_restore: replay history stores multiple turns")
	var container := _make_container()
	tests.add_child(container)
	container._store_replay_recording_for_turn(1, { "actions": [] })
	container._store_replay_recording_for_turn(2, { "actions": [] })
	container._store_replay_recording_for_turn(3, { "actions": [] })
	var turn_numbers: Array = container._get_replay_turn_numbers()
	if turn_numbers.size() != 3:
		tests._fail("expected three replay turns in history")
		container.free()
		return false
	if int(turn_numbers[0]) != 1 or int(turn_numbers[1]) != 2 or int(turn_numbers[2]) != 3:
		tests._fail("expected replay history order [1,2,3], got %s" % [turn_numbers])
		container.free()
		return false
	var turn2_entry: Dictionary = container._get_replay_history_entry(2)
	if int(turn2_entry.get("turn", 0)) != 2:
		tests._fail("expected to resolve turn 2 replay entry")
		container.free()
		return false
	var fallback_entry: Dictionary = container._get_replay_history_entry(999)
	if int(fallback_entry.get("turn", 0)) != 3:
		tests._fail("unknown turn should fall back to latest replay turn")
		container.free()
		return false
	tests._pass("replay history stores multiple turns")
	container.free()
	return true

static func _test_replay_history_respects_capacity(tests: Node) -> bool:
	tests._log("test_replay_restore: replay history enforces max turn window")
	var container := _make_container()
	tests.add_child(container)
	var max_history: int = UnitsContainer.MAX_REPLAY_TURN_HISTORY
	for turn_idx in range(1, max_history + 3):
		container._store_replay_recording_for_turn(turn_idx, { "actions": [] })
	var turn_numbers: Array = container._get_replay_turn_numbers()
	if turn_numbers.size() != max_history:
		tests._fail("expected replay history size %d, got %d" % [max_history, turn_numbers.size()])
		container.free()
		return false
	var expected_first_turn: int = 3
	if int(turn_numbers[0]) != expected_first_turn:
		tests._fail("expected oldest retained replay turn %d, got %d" % [expected_first_turn, int(turn_numbers[0])])
		container.free()
		return false
	var expected_last_turn: int = max_history + 2
	if int(turn_numbers[turn_numbers.size() - 1]) != expected_last_turn:
		tests._fail("expected latest retained replay turn %d, got %d" % [expected_last_turn, int(turn_numbers[turn_numbers.size() - 1])])
		container.free()
		return false
	tests._pass("replay history enforces max turn window")
	container.free()
	return true

static func _test_apply_scenario_uses_health_and_energy_overrides(tests: Node) -> bool:
	tests._log("test_replay_restore: apply_scenario applies unit health and energy overrides")
	var container := _make_container()
	tests.add_child(container)
	var scenario := {
		"groups": [
			{
				"name": "player",
				"units": [
					{"def_path": "res://src/unit/definitions/medic.tres", "cell": Vector2i(0, 0), "energy": 2},
					{"def_path": "res://src/unit/definitions/marine.tres", "cell": Vector2i(1, 0), "health": 3, "energy": 1},
				]
			},
			{"name": "opponent", "ai": true, "units": []},
		]
	}
	container.apply_scenario(scenario)
	var player_group := container.get_node_or_null("player")
	if player_group == null:
		tests._fail("player group should exist after apply_scenario")
		container.free()
		return false
	var medic: Unit = null
	var marine: Unit = null
	for child in player_group.get_children():
		if not child is Unit:
			continue
		if child.def and child.def.resource_path == "res://src/unit/definitions/medic.tres":
			medic = child
		elif child.def and child.def.resource_path == "res://src/unit/definitions/marine.tres":
			marine = child
	if medic == null or marine == null:
		tests._fail("apply_scenario should spawn both medic and marine")
		container.free()
		return false
	if medic.energy != 2:
		tests._fail("medic energy override should be 2, got %s" % medic.energy)
		container.free()
		return false
	if marine.health != 3:
		tests._fail("marine health override should be 3, got %s" % marine.health)
		container.free()
		return false
	if marine.energy != 1:
		tests._fail("marine energy override should be 1, got %s" % marine.energy)
		container.free()
		return false
	tests._pass("apply_scenario applies unit health and energy overrides")
	container.free()
	return true

static func _test_replay_summary_panel_hides_after_replay_finished(tests: Node) -> bool:
	tests._log("test_replay_restore: replay summary panel closes on replay_finished")
	var panel_scene := load("res://src/battle/replay_summary_panel.tscn") as PackedScene
	if panel_scene == null:
		tests._fail("expected replay_summary_panel scene to load")
		return false
	var panel := panel_scene.instantiate() as PanelContainer
	tests.add_child(panel)
	if panel.visible:
		tests._fail("replay summary panel should start hidden")
		panel.free()
		return false
	EventBus.show_replay_summary.emit(["Marine: Attack"], "Turn 2 actions")
	if not panel.visible:
		tests._fail("replay summary panel should become visible when summary is shown")
		panel.free()
		return false
	EventBus.replay_finished.emit()
	if panel.visible:
		tests._fail("replay summary panel should hide when replay finishes")
		panel.free()
		return false
	tests._pass("replay summary panel closes on replay_finished")
	panel.free()
	return true

static func _test_replay_summary_lines_group_by_phase_and_mark_cancelled(tests: Node) -> bool:
	tests._log("test_replay_restore: replay summary groups submitted actions by phase and marks cancelled actions")
	var container := _make_container()
	tests.add_child(container)
	var replay_recording := {
		"summary": [
			{
				"unit_id": 2,
				"unit_name": "Zergling",
				"action_key": "fast_move",
				"action_name": "Move",
				"action_type": "fast move",
				"cancelled": false
			},
			{
				"unit_id": 1,
				"unit_name": "Marine",
				"action_key": "attack_short",
				"action_name": "Attack",
				"action_type": "ability",
				"cancelled": true,
				"cancelled_reason": "eliminated_before_phase"
			}
		],
		"died_ids": [1],
		"before_state": {
			1: {"health": 1, "unit_name": "Marine"}
		},
		"damage_by_id": {1: 1}
	}
	var lines: Array = container._build_replay_summary_lines(replay_recording)
	if not lines.has("  Zergling: Move"):
		tests._fail("replay summary should include fast move submitted action line")
		container.free()
		return false
	if not lines.has("  Marine: Attack (cancelled: eliminated first)"):
		tests._fail("replay summary should mark eliminated-before-phase action as cancelled")
		container.free()
		return false
	var fast_move_idx: int = lines.find("Fast Move")
	var ability_idx: int = lines.find("Ability")
	if fast_move_idx < 0 or ability_idx < 0 or fast_move_idx >= ability_idx:
		tests._fail("replay summary should group lines by phase order (Fast Move before Ability)")
		container.free()
		return false
	tests._pass("replay summary groups by phase and marks cancelled actions")
	container.free()
	return true
