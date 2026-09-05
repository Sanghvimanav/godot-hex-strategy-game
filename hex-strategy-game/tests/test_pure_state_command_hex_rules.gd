extends RefCounted

const PureStateCommandHexRules = preload("res://src/simulation/pure_state_command_hex_rules.gd")
const PureStateGameRollout = preload("res://src/simulation/pure_state_game_rollout.gd")
const TurnExecutionCore = preload("res://src/battle/turn_execution_core.gd")


static func run_all(tests: Node) -> bool:
	var ok := true
	ok = _test_command_hexes_use_opposite_back_edges(tests) and ok
	ok = _test_capture_requires_one_complete_turn_and_same_unit(tests) and ok
	ok = _test_simultaneous_capture_is_a_draw(tests) and ok
	return ok


static func _test_command_hexes_use_opposite_back_edges(tests: Node) -> bool:
	tests._log("test_pure_state_command_hex_rules: centered opposite back edges")
	var state := {
		"hex_radius": 5,
		"groups": [
			{"name": "terran", "units": [_make_unit(1, Vector2i(4, 0))]},
			{"name": "zerg", "units": [_make_unit(2, Vector2i(-4, 0))]},
		]
	}
	var command_hexes := PureStateCommandHexRules.ensure_command_hexes(state, "terran", "zerg")
	if command_hexes.get("terran", []) != [5, 0]:
		tests._fail("Terran should own the centered +q back-edge command hex: %s" % command_hexes)
		return false
	if command_hexes.get("zerg", []) != [-5, 0]:
		tests._fail("Zerg should own the centered -q back-edge command hex: %s" % command_hexes)
		return false
	tests._pass("command hexes are centered on opposite back edges using the state hex radius")
	return true


static func _test_capture_requires_one_complete_turn_and_same_unit(tests: Node) -> bool:
	tests._log("test_pure_state_command_hex_rules: full-turn hold and relay rejection")
	var command_hexes := {
		"terran": [5, 0],
		"zerg": [-5, 0],
	}
	var before_entry := {
		"hex_radius": 5,
		"command_hexes": command_hexes.duplicate(true),
		"groups": [
			{"name": "terran", "units": [_make_unit(1, Vector2i(-4, 0)), _make_unit(3, Vector2i(-3, 0))]},
			{"name": "zerg", "units": [_make_unit(2, Vector2i(3, 0))]},
		]
	}
	var previous := PureStateCommandHexRules.initial_occupants(before_entry, "terran", "zerg", command_hexes)

	# Entering during this turn starts the hold but must not capture immediately.
	var after_entry := before_entry.duplicate(true)
	after_entry["groups"][0]["units"][0]["cell"] = [-5, 0]
	var entered := PureStateCommandHexRules.capture_after_complete_turn(
		after_entry,
		"terran",
		"zerg",
		command_hexes,
		previous
	)
	if bool((entered.get("completed", {}) as Dictionary).get("terran", false)):
		tests._fail("entering a command hex at the end of a turn must not capture immediately")
		return false

	# Remaining there through the next complete turn completes the capture.
	var held := PureStateCommandHexRules.capture_after_complete_turn(
		after_entry,
		"terran",
		"zerg",
		command_hexes,
		entered.get("occupants", {})
	)
	if not bool((held.get("completed", {}) as Dictionary).get("terran", false)):
		tests._fail("the same unit remaining on the command hex for a complete turn should capture")
		return false

	# Replacing the holder with a different unit does not satisfy the hold.
	var relay := after_entry.duplicate(true)
	relay["groups"][0]["units"][0]["cell"] = [-4, 0]
	relay["groups"][0]["units"][1]["cell"] = [-5, 0]
	var relayed := PureStateCommandHexRules.capture_after_complete_turn(
		relay,
		"terran",
		"zerg",
		command_hexes,
		entered.get("occupants", {})
	)
	if bool((relayed.get("completed", {}) as Dictionary).get("terran", false)):
		tests._fail("swapping a different unit onto the command hex must restart capture progress")
		return false
	tests._pass("capture requires the same enemy unit to hold the command hex across a full resolved turn")
	return true


static func _test_simultaneous_capture_is_a_draw(tests: Node) -> bool:
	tests._log("test_pure_state_command_hex_rules: simultaneous capture draw")
	var terran := _make_unit(1, Vector2i(-5, 0))
	var zerg := _make_unit(2, Vector2i(5, 0))
	# Active stun forces both sides to hold position for the resolved turn while
	# still exercising the normal GameplayAI -> simulator rollout pipeline.
	terran["effects"] = [{"kind": "Stun", "duration": 1, "params": {}, "pending_first_tick": false}]
	zerg["effects"] = [{"kind": "Stun", "duration": 1, "params": {}, "pending_first_tick": false}]
	var state := {
		"scenario_id": "simultaneous_command_capture",
		"hex_radius": 5,
		"command_hexes": {
			"terran": [5, 0],
			"zerg": [-5, 0],
		},
		"groups": [
			{"name": "terran", "resources": {}, "units": [terran]},
			{"name": "zerg", "resources": {}, "units": [zerg]},
		],
		"tile_resources": {},
	}
	var result := PureStateGameRollout.play_game(state, "terran", "zerg", 1, 8, 1, 1)
	if not bool(result.get("valid", false)):
		tests._fail("simultaneous command capture rollout should be valid: %s" % result)
		return false
	if str(result.get("status", "")) != "terminal":
		tests._fail("simultaneous capture should terminate the game: %s" % result)
		return false
	if str(result.get("winner", "not-empty")) != "":
		tests._fail("simultaneous capture must have no winner: %s" % result)
		return false
	if str(result.get("termination_reason", "")) != "simultaneous_command_hex_capture":
		tests._fail("simultaneous capture should report its explicit draw reason: %s" % result)
		return false
	if int(result.get("turns_played", 0)) != 1:
		tests._fail("both pre-positioned holders should complete capture after one full turn")
		return false
	tests._pass("simultaneous completed command-hex captures resolve as a draw")
	return true


static func _make_unit(unit_id: int, cell: Vector2i) -> Dictionary:
	var def_path := "res://src/unit/definitions/zergling.tres"
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
