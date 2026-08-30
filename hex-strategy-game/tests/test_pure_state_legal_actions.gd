extends RefCounted
## Tests for PureStateLegalActions: pure dictionary output, validation parity, and simulator compatibility.

const PureStateLegalActions = preload("res://src/simulation/pure_state_legal_actions.gd")
const PureStateSimulator = preload("res://src/simulation/pure_state_simulator.gd")
const ServerTurnExecutor = preload("res://src/server/server_turn_executor.gd")


static func run_all(tests: Node) -> bool:
	var ok := true
	ok = _test_missing_dead_and_stunned_units_have_no_actions(tests) and ok
	ok = _test_enumeration_does_not_mutate_state(tests) and ok
	ok = _test_marine_has_six_moves_six_attacks_and_rest(tests) and ok
	ok = _test_hex_radius_filters_off_board_targets(tests) and ok
	ok = _test_medic_has_self_and_six_adjacent_heal_targets(tests) and ok
	ok = _test_every_returned_action_passes_server_validation(tests) and ok
	ok = _test_returned_action_can_be_simulated(tests) and ok
	return ok


static func _make_marine_state(health: int = 2) -> Dictionary:
	return {
		"groups": [
			{
				"name": "terran",
				"ai": false,
				"units": [{
					"unit_id": 1,
					"def_path": "res://src/unit/definitions/marine.tres",
					"cell": [0, 0],
					"health": health,
					"max_health": 2,
					"energy": 0,
					"max_energy": 0,
				}],
			},
			{ "name": "zerg", "ai": false, "units": [] },
		]
	}


static func _make_medic_state() -> Dictionary:
	return {
		"groups": [
			{
				"name": "terran",
				"ai": false,
				"units": [{
					"unit_id": 7,
					"def_path": "res://src/unit/definitions/medic.tres",
					"cell": [0, 0],
					"health": 2,
					"max_health": 2,
					"energy": 4,
					"max_energy": 4,
				}],
			},
			{ "name": "zerg", "ai": false, "units": [] },
		]
	}


static func _test_missing_dead_and_stunned_units_have_no_actions(tests: Node) -> bool:
	tests._log("test_pure_state_legal_actions: missing/dead/stunned units")
	var state := _make_marine_state()
	if not PureStateLegalActions.get_legal_actions(state, 999).is_empty():
		tests._fail("missing unit should have no legal actions")
		return false
	var dead_state := _make_marine_state(0)
	if not PureStateLegalActions.get_legal_actions(dead_state, 1).is_empty():
		tests._fail("dead unit should have no legal actions")
		return false
	var stunned_state := _make_marine_state()
	stunned_state.groups[0].units[0]["effects"] = [{
		"kind": "Stun",
		"duration": 1,
		"params": {},
		"pending_first_tick": false,
	}]
	if not PureStateLegalActions.get_legal_actions(stunned_state, 1).is_empty():
		tests._fail("actively stunned unit should have no executable planned actions")
		return false
	tests._pass("missing/dead/stunned units have no legal actions")
	return true


static func _test_enumeration_does_not_mutate_state(tests: Node) -> bool:
	tests._log("test_pure_state_legal_actions: enumeration does not mutate state")
	var state := _make_marine_state()
	var original := state.duplicate(true)
	PureStateLegalActions.get_legal_actions(state, 1)
	if state != original:
		tests._fail("legal action enumeration should not mutate game state")
		return false
	tests._pass("enumeration does not mutate state")
	return true


static func _test_marine_has_six_moves_six_attacks_and_rest(tests: Node) -> bool:
	tests._log("test_pure_state_legal_actions: marine local action enumeration")
	var actions := PureStateLegalActions.get_legal_actions(_make_marine_state(), 1)
	var move_count := 0
	var attack_count := 0
	var rest_count := 0
	for action in actions:
		match str(action.get("action_key", "")):
			"move_short": move_count += 1
			"attack_short": attack_count += 1
			"rest_no_energy": rest_count += 1
	if move_count != 6:
		tests._fail("marine should have 6 one-hex moves, got %d" % move_count)
		return false
	if attack_count != 6:
		tests._fail("marine should have 6 adjacent attacks, got %d" % attack_count)
		return false
	if rest_count != 1:
		tests._fail("marine should have one rest action, got %d" % rest_count)
		return false
	tests._pass("marine has six moves, six attacks, and rest")
	return true


static func _test_hex_radius_filters_off_board_targets(tests: Node) -> bool:
	tests._log("test_pure_state_legal_actions: hex radius filters off-board targets")
	var state := _make_marine_state()
	state["hex_radius"] = 1
	state.groups[0].units[0]["cell"] = [1, 0]
	var actions := PureStateLegalActions.get_legal_actions(state, 1)
	var move_count := 0
	var attack_count := 0
	for action in actions:
		var endpoint: Array = action.get("end_point", [0, 0])
		if HexGrid.hex_distance(0, 0, int(endpoint[0]), int(endpoint[1])) > 1:
			tests._fail("enumerator returned off-board target %s" % endpoint)
			return false
		if str(action.get("action_key", "")) == "move_short":
			move_count += 1
		elif str(action.get("action_key", "")) == "attack_short":
			attack_count += 1
	if move_count != 3 or attack_count != 3:
		tests._fail("radius-1 edge marine should have 3 moves and 3 attacks, got %d/%d" % [move_count, attack_count])
		return false
	tests._pass("hex radius filters off-board targets")
	return true


static func _test_medic_has_self_and_six_adjacent_heal_targets(tests: Node) -> bool:
	tests._log("test_pure_state_legal_actions: medic self-or-adjacent targeting")
	var state := _make_medic_state()
	var actions := PureStateLegalActions.get_legal_actions(state, 7)
	var heal_targets: Dictionary = {}
	for action in actions:
		if str(action.get("action_key", "")) != "heal_adjacent":
			continue
		var endpoint: Array = action.get("end_point", [])
		heal_targets[str(endpoint)] = true
		var validation := ServerTurnExecutor.validate_action(state, action, "terran")
		if not bool(validation.get("valid", false)):
			tests._fail("heal target should pass server validation: %s" % action)
			return false
	if heal_targets.size() != 7:
		tests._fail("medic should have self + 6 adjacent heal targets, got %d" % heal_targets.size())
		return false
	if not heal_targets.has(str([0, 0])):
		tests._fail("medic heal targets should include self")
		return false
	tests._pass("medic has self + six adjacent heal targets")
	return true


static func _test_every_returned_action_passes_server_validation(tests: Node) -> bool:
	tests._log("test_pure_state_legal_actions: validation parity")
	var state := _make_marine_state()
	var actions := PureStateLegalActions.get_legal_actions(state, 1)
	if actions.is_empty():
		tests._fail("expected at least one legal action")
		return false
	for action in actions:
		var validation := ServerTurnExecutor.validate_action(state, action, "terran")
		if not bool(validation.get("valid", false)):
			tests._fail("enumerator returned invalid action %s: %s" % [action, validation])
			return false
	tests._pass("every returned action passes server validation")
	return true


static func _test_returned_action_can_be_simulated(tests: Node) -> bool:
	tests._log("test_pure_state_legal_actions: simulator compatibility")
	var state := _make_marine_state()
	var actions := PureStateLegalActions.get_legal_actions(state, 1)
	var selected: Dictionary = {}
	for action in actions:
		if str(action.get("action_key", "")) == "move_short":
			selected = action
			break
	if selected.is_empty():
		tests._fail("expected a move action to simulate")
		return false
	var result := PureStateSimulator.simulate_turn(state, { "terran": [selected], "zerg": [] })
	var next_unit: Dictionary = result.next_state.get("groups", [])[0].get("units", [])[0]
	if next_unit.get("cell", [0, 0]) == [0, 0]:
		tests._fail("simulating enumerated move should change unit cell")
		return false
	tests._pass("returned legal action can be simulated")
	return true
