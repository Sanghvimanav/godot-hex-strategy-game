extends RefCounted
class_name ServerTurnExecutor
## Server-facing turn validation and execution. Delegates execution to TurnExecutionCore
## so multiplayer and single-player use the same rules.

## Use TurnExecutionCore as single source for action type constants.
const MOVE_TYPES: Array[String] = TurnExecutionCore.MOVE_TYPES

static func _has_extractable_resource(game_state: Dictionary, q: int, r: int) -> bool:
	var tile_resources = game_state.get("tile_resources", {})
	if not (tile_resources is Dictionary):
		return false
	var key := HexGrid.get_cell_key(q, r)
	if not tile_resources.has(key):
		return false
	var entry = tile_resources[key]
	if entry is Dictionary:
		return int(entry.get("amount", entry.get("resource_amount", 0))) > 0
	return int(entry) > 0


static func validate_action(game_state: Dictionary, action: Dictionary, group_name: String) -> Dictionary:
	var unit_id: int = action.get("unit_id", -1)
	var action_key: String = str(action.get("action_key", ""))
	var path: Array = action.get("path", [])
	var end_point = action.get("end_point", [0, 0])
	var found = TurnExecutionCore.find_unit_by_id(game_state, unit_id)
	if found.is_empty():
		return { valid = false, error = "Unit not found" }
	var unit: Dictionary = found.unit
	var group: Dictionary = found.group
	if group.get("name", "") != group_name:
		return { valid = false, error = "Unit not in your group" }
	if unit.get("health", 0) <= 0:
		return { valid = false, error = "Unit is dead" }

	var def_path: String = unit.get("def_path", "")
	var def_dict: Dictionary = TurnExecutionCore.get_unit_def(def_path)
	var all_keys: Array = []
	all_keys.append_array(def_dict.get("move_action_keys", []))
	all_keys.append_array(def_dict.get("ability_action_keys", []))
	all_keys.append_array(def_dict.get("passive_action_keys", []))
	if action_key not in all_keys:
		return { valid = false, error = "Unit cannot perform %s" % action_key }

	var config: Dictionary = Actions.get_action_config(action_key)
	if config.is_empty():
		return { valid = false, error = "Unknown action %s" % action_key }

	var uc: Array = unit.get("cell", [0, 0])
	var uq: int = int(uc[0])
	var ur: int = int(uc[1])
	var end_cell: Vector2i = Vector2i(int(end_point[0]), int(end_point[1])) if end_point is Array and end_point.size() >= 2 else Vector2i(uq, ur)

	if config.has("min_range") and config.has("max_range"):
		var dist: int = HexGrid.hex_distance(uq, ur, end_cell.x, end_cell.y)
		if dist < int(config.min_range) or dist > int(config.max_range):
			return { valid = false, error = "Target out of range" }

	if int(config.get("energy_consumption", 0)) > 0 and unit.get("max_energy", 0) > 0:
		if unit.get("energy", 0) < int(config.energy_consumption):
			return { valid = false, error = "Not enough energy" }

	var atype: String = config.get("type", "")
	if atype == "extract":
		if not _has_extractable_resource(game_state, uq, ur):
			return { valid = false, error = "No resource to extract on this tile" }
	if atype in MOVE_TYPES:
		var full_path: Array = path.duplicate()
		full_path.append([end_cell.x, end_cell.y])
		if full_path.size() < 2:
			return { valid = false, error = "Invalid move path" }
		var expected: Array = HexGrid.build_path_to(uq, ur, end_cell.x, end_cell.y)
		if full_path.size() != expected.size() + 1:
			return { valid = false, error = "Invalid path" }
		for i in expected.size():
			var p: Vector2 = expected[i]
			var fp: Array = full_path[i]
			if int(p.x) != int(fp[0]) or int(p.y) != int(fp[1]):
				return { valid = false, error = "Invalid path" }

	return { valid = true }


static func execute_turn(game_state: Dictionary, player_actions: Dictionary) -> Dictionary:
	return TurnExecutionCore.execute_turn(game_state, player_actions)


static func check_win_condition(game_state: Dictionary) -> String:
	return TurnExecutionCore.check_win_condition(game_state)
