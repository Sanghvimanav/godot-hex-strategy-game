extends RefCounted
## Regression tests for stun timing + replay effect restoration.

const TurnExecutor = preload("res://src/battle/turn_executor.gd")
const UnitScript = preload("res://src/unit/unit.gd")
const UnitEffect = preload("res://src/unit/effect.gd")

static func run_all(tests: Node) -> bool:
	var ok := true
	ok = _test_stun_registers_and_persists_to_next_turn(tests) and ok
	ok = _test_stun_replay_roundtrip_matches_next_turn_state(tests) and ok
	ok = _test_stun_debug_scenario_exists(tests) and ok
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
	var has_ai_viper := false
	for g in scenario.get("groups", []):
		var group_name: String = str(g.get("name", ""))
		var is_ai: bool = bool(g.get("ai", false))
		for u in g.get("units", []):
			var def_path: String = str(u.get("def_path", ""))
			if group_name == "player" and def_path == "res://src/unit/definitions/terran_base.tres":
				has_player_base = true
			if group_name == "opponent" and is_ai and def_path == "res://src/unit/definitions/viper.tres":
				has_ai_viper = true
	if not has_player_base:
		tests._fail("stun_replay_debug should include a player Terran Base")
		return false
	if not has_ai_viper:
		tests._fail("stun_replay_debug should include an AI Viper opponent")
		return false
	tests._pass("stun replay debug scenario exists")
	return true
