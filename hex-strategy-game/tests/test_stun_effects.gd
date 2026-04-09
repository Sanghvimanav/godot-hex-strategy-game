extends RefCounted
## Regression tests for stun timing + replay effect restoration.

const TurnExecutor = preload("res://src/battle/turn_executor.gd")
const UnitScript = preload("res://src/unit/unit.gd")
const UnitEffect = preload("res://src/unit/effect.gd")

const TurnExecutionCore = preload("res://src/battle/turn_execution_core.gd")

static func run_all(tests: Node) -> bool:
	var ok := true
	ok = _test_stun_registers_and_persists_to_next_turn(tests) and ok
	ok = _test_stun_replay_roundtrip_matches_next_turn_state(tests) and ok
	ok = _test_stun_debug_scenario_exists(tests) and ok
	ok = _test_attack_hydralisk_stun_blocks_next_turn_move(tests) and ok
	return ok

static func _make_execution_context(tests: Node) -> TurnExecutor.ExecutionContext:
	var recording: Dictionary = {
		"actions": [],
		"died_ids": [],
		"summary": [],
		"applied_effects": [],
	}
	return TurnExecutor.ExecutionContext.new([], true, recording, Callable(), tests.get_tree())

static func _test_stun_registers_and_persists_to_next_turn(tests: Node) -> bool:
	tests._log("test_stun_effects: stun is recorded and still active after immediate end-turn tick")
	var unit = UnitScript.new()
	var ctx := _make_execution_context(tests)
	TurnExecutor._apply_stun_effect(ctx, unit, 1)
	if unit.active_effects.size() != 1:
		tests._fail("stun should be added during execution")
		return false
	if unit.get_effects_display_text() != "Stun (1)":
		tests._fail("stun display text should be 'Stun (1)' right after application")
		return false
	var applied: Array = ctx.recording.get("applied_effects", [])
	if applied.size() != 1:
		tests._fail("stun should be registered in recording.applied_effects")
		return false
	if unit.get_disabled_action_types().size() != 0:
		tests._fail("newly applied stun should not disable actions until next turn")
		return false
	unit.tick_effects()
	if unit.get_effects_display_text() != "Stun (1)":
		tests._fail("newly applied stun should persist through the immediate end-turn tick")
		return false
	if unit.get_disabled_action_types().size() != Actions.ACTION_ORDER.size():
		tests._fail("stunned unit should have all action types disabled on the next turn")
		return false
	unit.tick_effects()
	if not unit.active_effects.is_empty():
		tests._fail("stun should expire after the stunned turn ends")
		return false
	tests._pass("stun is recorded and persists to next turn")
	return true

static func _test_stun_replay_roundtrip_matches_next_turn_state(tests: Node) -> bool:
	tests._log("test_stun_effects: replay restore keeps stunned next-turn state")
	var unit = UnitScript.new()
	var ctx := _make_execution_context(tests)
	TurnExecutor._apply_stun_effect(ctx, unit, 1)
	unit.tick_effects()  # Move to the start of the stunned turn.
	var expected_text: String = unit.get_effects_display_text()
	if expected_text != "Stun (1)":
		tests._fail("expected next-turn stun display to be 'Stun (1)', got %s" % expected_text)
		return false
	unit.active_effects.clear()  # Simulate replay restore to before_state.
	var applied: Array = ctx.recording.get("applied_effects", [])
	if applied.is_empty():
		tests._fail("expected applied_effects entry for replay test")
		return false
	var effect_dict: Dictionary = applied[0].get("effect", {})
	var replay_effect = UnitEffect.from_dict(effect_dict)
	unit.add_effect(replay_effect, false)
	if unit.get_effects_display_text() != expected_text:
		tests._fail("replay-applied stun should match live next-turn stun state")
		return false
	if unit.get_disabled_action_types().size() != Actions.ACTION_ORDER.size():
		tests._fail("replay-applied stun should still disable all action types")
		return false
	unit.tick_effects()
	if not unit.active_effects.is_empty():
		tests._fail("replay-applied stun should expire after one stunned turn")
		return false
	tests._pass("replay restore keeps stunned next-turn state")
	return true

static func _test_stun_debug_scenario_exists(tests: Node) -> bool:
	tests._log("test_stun_effects: stun replay debug scenario is available")
	var scenario: Dictionary = Scenarios.get_scenario_by_id("stun_replay_debug")
	if scenario.is_empty():
		tests._fail("stun_replay_debug scenario should exist")
		return false
	var has_player_base := false
	var has_ai_hydralisk := false
	for g in scenario.get("groups", []):
		var group_name: String = str(g.get("name", ""))
		var is_ai: bool = bool(g.get("ai", false))
		for u in g.get("units", []):
			var def_path: String = str(u.get("def_path", ""))
			if group_name == "player" and def_path == "res://src/unit/definitions/terran_base.tres":
				has_player_base = true
			if group_name == "opponent" and is_ai and def_path == "res://src/unit/definitions/hydralisk.tres":
				has_ai_hydralisk = true
	if not has_player_base:
		tests._fail("stun_replay_debug should include a player Terran Base")
		return false
	if not has_ai_hydralisk:
		tests._fail("stun_replay_debug should include an AI Hydralisk opponent")
		return false
	tests._pass("stun replay debug scenario exists")
	return true

## End-to-end Core behavior: attack_hydralisk applies stun, next turn is blocked, then stun expires.
static func _test_attack_hydralisk_stun_blocks_next_turn_move(tests: Node) -> bool:
	tests._log("test_stun_effects: attack_hydralisk stun starts next turn and expires after one blocked turn")
	# Turn 1: Hydralisk at (0,0), target at (2,0). Hydralisk attacks and stuns.
	# Target also uses a slow action this turn, which should still execute.
	var game_state_t1 := {
		"groups": [
			{ "name": "player", "ai": false, "units": [
				{ "unit_id": 1, "def_path": "res://src/unit/definitions/hydralisk.tres", "cell": [0, 0], "health": 2, "max_health": 2, "energy": 0, "max_energy": 0 }
			]},
			{ "name": "opponent", "ai": false, "units": [
				{ "unit_id": 2, "def_path": "res://src/unit/definitions/marine.tres", "cell": [2, 0], "health": 3, "max_health": 3, "energy": 0, "max_energy": 0 }
			]}
		]
	}
	var actions_t1 := {
		"player": [{ "unit_id": 1, "action_key": "attack_hydralisk", "path": [], "end_point": [2, 0] }],
		"opponent": [{ "unit_id": 2, "action_key": "reload", "path": [], "end_point": [0, 0] }]
	}
	TurnExecutionCore.execute_turn(game_state_t1, actions_t1)
	var target_found := TurnExecutionCore.find_unit_by_id(game_state_t1, 2)
	if target_found.is_empty():
		tests._fail("target should exist after turn 1")
		return false
	var energy_after_t1: int = int(target_found.unit.get("energy", -1))
	if energy_after_t1 != 3:
		tests._fail("target should still execute same-turn slow action before stun takes effect; expected energy 3, got %d" % energy_after_t1)
		return false
	var effects_after_t1: Array = target_found.unit.get("effects", [])
	if effects_after_t1.is_empty():
		tests._fail("attack_hydralisk should apply stun effect to target for next turn")
		return false
	# Turn 2: Stunned target tries to move.
	var move_path: Array = []
	for p in HexGrid.build_path_to(2, 0, 3, 0):
		move_path.append([int(p.x), int(p.y)])
	var actions_t2 := {
		"player": [],
		"opponent": [{ "unit_id": 2, "action_key": "move_short", "path": move_path, "end_point": [3, 0] }]
	}
	TurnExecutionCore.execute_turn(game_state_t1, actions_t2)
	var target_after := TurnExecutionCore.find_unit_by_id(game_state_t1, 2)
	if target_after.is_empty():
		tests._fail("target should exist after turn 2")
		return false
	var cell: Array = target_after.unit.get("cell", [])
	if cell != [2, 0]:
		tests._fail("stunned target must not move; expected [2,0], got %s" % cell)
		return false
	var effects_after_t2: Array = target_after.unit.get("effects", [])
	if not effects_after_t2.is_empty():
		tests._fail("stun should expire after the blocked turn, got effects %s" % effects_after_t2)
		return false
	# Turn 3: same move is now allowed.
	TurnExecutionCore.execute_turn(game_state_t1, actions_t2)
	var target_after_expire := TurnExecutionCore.find_unit_by_id(game_state_t1, 2)
	if target_after_expire.is_empty():
		tests._fail("target should exist after turn 3")
		return false
	var cell_after_expire: Array = target_after_expire.unit.get("cell", [])
	if cell_after_expire != [3, 0]:
		tests._fail("target should move after stun expires; expected [3,0], got %s" % cell_after_expire)
		return false
	tests._pass("attack_hydralisk stun blocks next-turn move")
	return true
