extends RefCounted
## Tests for PureStateSimulator: immutable inputs and deterministic data-only turn resolution.

const PureStateSimulator = preload("res://src/simulation/pure_state_simulator.gd")


static func run_all(tests: Node) -> bool:
	var ok := true
	ok = _test_simulate_turn_does_not_mutate_inputs(tests) and ok
	ok = _test_simulate_turn_returns_resolved_next_state(tests) and ok
	ok = _test_simulate_turn_is_deterministic(tests) and ok
	return ok


static func _make_attack_fixture() -> Dictionary:
	return {
		"game_state": {
			"groups": [
				{
					"name": "terran",
					"ai": false,
					"units": [
						{
							"unit_id": 1,
							"def_path": "res://src/unit/definitions/marine.tres",
							"cell": [1, 0],
							"health": 3,
							"max_health": 3,
							"energy": 4,
							"max_energy": 4,
						}
					],
				},
				{
					"name": "zerg",
					"ai": false,
					"units": [
						{
							"unit_id": 2,
							"def_path": "res://src/unit/definitions/zergling.tres",
							"cell": [0, 0],
							"health": 1,
							"max_health": 1,
							"energy": 0,
							"max_energy": 0,
						}
					],
				},
			]
		},
		"player_actions": {
			"terran": [
				{
					"unit_id": 1,
					"action_key": "attack_short",
					"path": [],
					"end_point": [0, 0],
				}
			],
			"zerg": [],
		},
	}


static func _test_simulate_turn_does_not_mutate_inputs(tests: Node) -> bool:
	tests._log("test_pure_state_simulator: simulate_turn does not mutate inputs")
	var fixture: Dictionary = _make_attack_fixture()
	var game_state: Dictionary = fixture.game_state
	var player_actions: Dictionary = fixture.player_actions
	var original_state: Dictionary = game_state.duplicate(true)
	var original_actions: Dictionary = player_actions.duplicate(true)

	PureStateSimulator.simulate_turn(game_state, player_actions)

	if game_state != original_state:
		tests._fail("simulate_turn should not mutate caller game_state")
		return false
	if player_actions != original_actions:
		tests._fail("simulate_turn should not mutate caller player_actions")
		return false
	tests._pass("simulate_turn does not mutate inputs")
	return true


static func _test_simulate_turn_returns_resolved_next_state(tests: Node) -> bool:
	tests._log("test_pure_state_simulator: simulate_turn returns resolved next state")
	var fixture: Dictionary = _make_attack_fixture()
	var result: Dictionary = PureStateSimulator.simulate_turn(fixture.game_state, fixture.player_actions)
	if not result.has("next_state") or not result.has("recording"):
		tests._fail("simulate_turn should return next_state and recording")
		return false
	var next_state: Dictionary = result.next_state
	var zerg_units: Array = next_state.get("groups", [])[1].get("units", [])
	if not zerg_units.is_empty():
		tests._fail("resolved next_state should remove eliminated zergling")
		return false
	var died_ids: Array = result.recording.get("died_ids", [])
	if 2 not in died_ids:
		tests._fail("recording should include eliminated zergling id")
		return false
	tests._pass("simulate_turn returns resolved next state")
	return true


static func _test_simulate_turn_is_deterministic(tests: Node) -> bool:
	tests._log("test_pure_state_simulator: identical inputs produce identical outputs")
	var fixture: Dictionary = _make_attack_fixture()
	var result_a: Dictionary = PureStateSimulator.simulate_turn(fixture.game_state, fixture.player_actions)
	var result_b: Dictionary = PureStateSimulator.simulate_turn(fixture.game_state, fixture.player_actions)
	if result_a != result_b:
		tests._fail("identical pure-state simulations should produce identical results")
		return false
	tests._pass("identical inputs produce identical outputs")
	return true
