extends RefCounted

const PureStateGameRollout = preload("res://src/simulation/pure_state_game_rollout.gd")
const TurnExecutionCore = preload("res://src/battle/turn_execution_core.gd")


static func run_all(tests: Node) -> bool:
	var ok := true
	ok = _test_rollout_reaches_terminal_collapse_without_mutation(tests) and ok
	ok = _test_rollout_reports_turn_limit_deterministically(tests) and ok
	ok = _test_non_progress_streak_is_recorded(tests) and ok
	ok = _test_five_turn_mixed_force_game(tests) and ok
	return ok


static func _test_rollout_reaches_terminal_collapse_without_mutation(tests: Node) -> bool:
	tests._log("test_pure_state_game_rollout: terminal collapse smoke game")
	var state := _collapse_state()
	var before := state.duplicate(true)
	state["turn_index"] = 7
	before = state.duplicate(true)
	var result := PureStateGameRollout.play_game(state, "zerg", "terran", 3, 8, 2, 2, true)
	if state != before:
		tests._fail("full-game rollout must not mutate source state")
		return false
	if not bool(result.get("valid", false)):
		tests._fail("collapse rollout should be valid: %s" % result)
		return false
	if str(result.get("status", "")) != "terminal":
		tests._fail("collapse rollout should terminate, got %s" % result.get("status", ""))
		return false
	if str(result.get("winner", "")) != "zerg":
		tests._fail("collapse rollout should produce Zerg winner, got %s" % result.get("winner", ""))
		return false
	if int(result.get("turns_played", 0)) != 1:
		tests._fail("collapse should finish in one simulated game turn")
		return false
	var counts: Dictionary = result.get("final_alive_counts", {})
	if int(counts.get("terran", -1)) != 0 or int(counts.get("zerg", -1)) != 4:
		tests._fail("unexpected final collapse counts: %s" % counts)
		return false
	var history: Array = result.get("history", [])
	if int(history[0].get("state_before", {}).get("turn_index", -1)) != 7 or int(history[0].get("state_after", {}).get("turn_index", -1)) != 8:
		tests._fail("continuation rollout must preserve and advance the neural turn feature")
		return false
	if history.size() != 1:
		tests._fail("terminal one-turn game should record exactly one history entry")
		return false
	tests._log("  winner=%s turns=%d final=%s" % [
		str(result.get("winner", "")),
		int(result.get("turns_played", 0)),
		str(counts),
	])
	tests._pass("full-game rollout resolves both AI plans simultaneously through terminal outcome")
	return true


static func _test_rollout_reports_turn_limit_deterministically(tests: Node) -> bool:
	tests._log("test_pure_state_game_rollout: deterministic multi-turn capped game")
	var state := _distant_scout_vs_zergling_state()
	# 1x1 search keeps this smoke test cheap while still exercising two complete
	# plan -> simulate -> new-state cycles.
	var first := PureStateGameRollout.play_game(state, "terran", "zerg", 2, 8, 1, 1)
	var second := PureStateGameRollout.play_game(state, "terran", "zerg", 2, 8, 1, 1)
	if not bool(first.get("valid", false)) or not bool(second.get("valid", false)):
		tests._fail("turn-limit rollouts should be valid")
		return false
	if str(first.get("status", "")) != "turn_limit" or str(first.get("winner", "")) != "":
		tests._fail("nonterminal capped game should report turn_limit with no winner: %s" % first)
		return false
	if int(first.get("turns_played", 0)) != 2:
		tests._fail("multi-turn smoke game should play exactly two turns")
		return false
	var history: Array = first.get("history", [])
	if history.size() != 2:
		tests._fail("two-turn capped game should record two action-history entries")
		return false
	if first.get("final_state", {}) != second.get("final_state", {}):
		tests._fail("identical full-game rollout inputs should produce identical final state")
		return false
	if first.get("history", []) != second.get("history", []):
		tests._fail("identical full-game rollout inputs should produce identical action history")
		return false
	var counts: Dictionary = first.get("final_alive_counts", {})
	if int(counts.get("terran", 0)) != 1 or int(counts.get("zerg", 0)) != 1:
		tests._fail("two distant turns should leave both units alive: %s" % counts)
		return false
	tests._log("  status=%s turns=%d final=%s" % [
		str(first.get("status", "")),
		int(first.get("turns_played", 0)),
		str(counts),
	])
	tests._pass("full-game rollout iterates across turns deterministically and reports capped games explicitly")
	return true


static func _test_non_progress_streak_is_recorded(tests: Node) -> bool:
	tests._log("test_pure_state_game_rollout: non-progress streak diagnostic")
	var terran := _make_unit(1, "res://src/unit/definitions/marine.tres", Vector2i(2, 0))
	var zerg := _make_unit(2, "res://src/unit/definitions/zergling.tres", Vector2i(-2, 0))
	terran["effects"] = [{"kind": "Stun", "duration": 1, "params": {}, "pending_first_tick": false}]
	zerg["effects"] = [{"kind": "Stun", "duration": 1, "params": {}, "pending_first_tick": false}]
	var state := {
		"scenario_id": "rollout_non_progress",
		"hex_radius": 5,
		"groups": [
			{"name": "terran", "resources": {}, "units": [terran]},
			{"name": "zerg", "resources": {}, "units": [zerg]},
		],
		"tile_resources": {},
	}
	var result := PureStateGameRollout.play_game(state, "terran", "zerg", 1, 8, 1, 1)
	if not bool(result.get("valid", false)):
		tests._fail("forced-hold non-progress rollout should remain valid: %s" % result)
		return false
	var history: Array = result.get("history", [])
	if history.size() != 1:
		tests._fail("one-turn forced hold should record one diagnostic turn: %s" % history)
		return false
	var turn: Dictionary = history[0]
	if bool(turn.get("made_strategic_progress", true)):
		tests._fail("stun-only effect ticking should not count as strategic progress: %s" % turn)
		return false
	if int(turn.get("non_progress_streak", 0)) != 1 or int(result.get("max_non_progress_streak", 0)) != 1:
		tests._fail("non-progress turn should expose streak=1 in history and result: %s" % result)
		return false
	tests._pass("rollout diagnostics distinguish effect ticking from real movement/combat/resource/objective progress")
	return true


static func _test_five_turn_mixed_force_game(tests: Node) -> bool:
	tests._log("test_pure_state_game_rollout: five-turn mixed-force game")
	var state := _mixed_force_state()
	var before := state.duplicate(true)
	# 2x2 response budgets preserve some robust choice while keeping this longer
	# observational rollout inexpensive enough for normal CI.
	var result := PureStateGameRollout.play_game(state, "terran", "zerg", 5, 8, 2, 2)
	if state != before:
		tests._fail("mixed-force rollout must not mutate source state")
		return false
	if not bool(result.get("valid", false)):
		tests._fail("mixed-force rollout should complete without search/simulation failure: %s" % result.get("status", ""))
		return false
	var turns := int(result.get("turns_played", 0))
	if turns <= 0 or turns > 5:
		tests._fail("mixed-force rollout should play between 1 and 5 turns, got %d" % turns)
		return false
	var status := str(result.get("status", ""))
	if status != "terminal" and status != "turn_limit":
		tests._fail("mixed-force rollout should end terminal or at turn limit, got %s" % status)
		return false
	var history: Array = result.get("history", [])
	if history.size() != turns:
		tests._fail("mixed-force history should contain one entry per simulated turn")
		return false

	for turn_variant in history:
		if not (turn_variant is Dictionary):
			continue
		var turn: Dictionary = turn_variant
		tests._log("  turn %d terran=%s zerg=%s alive=%s" % [
			int(turn.get("turn", 0)),
			_action_summary(turn.get("terran_actions", []) as Array),
			_action_summary(turn.get("zerg_actions", []) as Array),
			str(turn.get("alive_after", {})),
		])

	var counts: Dictionary = result.get("final_alive_counts", {})
	tests._log("  result status=%s winner=%s turns=%d final=%s" % [
		status,
		str(result.get("winner", "")),
		turns,
		str(counts),
	])
	tests._pass("mixed Marine/Scout vs Zergling/Baneling game rolls forward for up to five turns")
	return true


static func _action_summary(actions: Array) -> String:
	var parts: Array[String] = []
	for action_variant in actions:
		if not (action_variant is Dictionary):
			continue
		var action: Dictionary = action_variant
		parts.append("U%d %s -> %s" % [
			int(action.get("unit_id", -1)),
			str(action.get("action_key", "?")),
			str(action.get("end_point", [])),
		])
	return "; ".join(parts)


static func _collapse_state() -> Dictionary:
	return {
		"scenario_id": "rollout_collapse",
		"hex_radius": 5,
		"groups": [
			{"name": "terran", "resources": {}, "units": [
				_make_unit(1, "res://src/unit/definitions/marine.tres", Vector2i(-2, 1)),
				_make_unit(2, "res://src/unit/definitions/marine.tres", Vector2i(-2, 1)),
				_make_unit(3, "res://src/unit/definitions/marine.tres", Vector2i(-2, 1)),
			]},
			{"name": "zerg", "resources": {}, "units": [
				_make_unit(4, "res://src/unit/definitions/zergling.tres", Vector2i(-3, 2)),
				_make_unit(5, "res://src/unit/definitions/zergling.tres", Vector2i(-3, 2)),
				_make_unit(6, "res://src/unit/definitions/zergling.tres", Vector2i(-3, 2)),
				_make_unit(7, "res://src/unit/definitions/zergling.tres", Vector2i(-3, 2)),
			]},
		],
		"tile_resources": {},
	}


static func _distant_scout_vs_zergling_state() -> Dictionary:
	return {
		"scenario_id": "rollout_turn_limit",
		"hex_radius": 5,
		"groups": [
			{"name": "terran", "resources": {}, "units": [
				_make_unit(1, "res://src/unit/definitions/scout.tres", Vector2i(4, 0)),
			]},
			{"name": "zerg", "resources": {}, "units": [
				_make_unit(2, "res://src/unit/definitions/zergling.tres", Vector2i(-4, 0)),
			]},
		],
		"tile_resources": {},
	}


static func _mixed_force_state() -> Dictionary:
	return {
		"scenario_id": "rollout_mixed_force_five_turn",
		"hex_radius": 5,
		"groups": [
			{"name": "terran", "resources": {}, "units": [
				_make_unit(1, "res://src/unit/definitions/marine.tres", Vector2i(2, -1)),
				_make_unit(2, "res://src/unit/definitions/marine.tres", Vector2i(2, 0)),
				_make_unit(3, "res://src/unit/definitions/scout.tres", Vector2i(2, 1)),
			]},
			{"name": "zerg", "resources": {}, "units": [
				_make_unit(4, "res://src/unit/definitions/zergling.tres", Vector2i(-3, -1)),
				_make_unit(5, "res://src/unit/definitions/zergling.tres", Vector2i(-3, 0)),
				_make_unit(6, "res://src/unit/definitions/zergling.tres", Vector2i(-3, 1)),
				_make_unit(7, "res://src/unit/definitions/baneling.tres", Vector2i(-4, 0)),
			]},
		],
		"tile_resources": {},
	}


static func _make_unit(unit_id: int, def_path: String, cell: Vector2i) -> Dictionary:
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
