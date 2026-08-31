extends RefCounted

const PureStateGameRollout = preload("res://src/simulation/pure_state_game_rollout.gd")
const TurnExecutionCore = preload("res://src/battle/turn_execution_core.gd")


static func run_all(tests: Node) -> bool:
	tests._log("test_pure_state_game_rollout_budget_matrix: mixed-force 2x2 / 4x4 / 8x8")
	var ok := true
	for budget in [2, 4, 8]:
		var state := _mixed_force_state()
		var result := PureStateGameRollout.play_game(state, "terran", "zerg", 5, 8, budget, budget)
		if not bool(result.get("valid", false)):
			tests._fail("%dx%d rollout should be valid, got %s" % [budget, budget, str(result.get("status", ""))])
			ok = false
			continue
		var history: Array = result.get("history", [])
		tests._log("  === %dx%d ===" % [budget, budget])
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
		tests._log("  result %dx%d status=%s winner=%s turns=%d final=%s" % [
			budget,
			budget,
			str(result.get("status", "")),
			str(result.get("winner", "")),
			int(result.get("turns_played", 0)),
			str(result.get("final_alive_counts", {})),
		])
	if ok:
		tests._pass("mixed-force rollout budget matrix completed for 2x2, 4x4, and 8x8")
	return ok


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


static func _mixed_force_state() -> Dictionary:
	return {
		"scenario_id": "rollout_mixed_force_budget_matrix",
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
