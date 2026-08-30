extends RefCounted
class_name PureStateLegalActions
## Data-only legal action enumeration for search / neural AI.
##
## Generates plain Dictionary actions directly from dictionary game state, then
## validates each candidate through ServerTurnExecutor so multiplayer validation
## remains the single source of truth for legality.

const ServerTurnExecutor = preload("res://src/server/server_turn_executor.gd")
const TurnExecutionCore = preload("res://src/battle/turn_execution_core.gd")


## Returns every currently legal planned action for unit_id as plain dictionaries:
## { unit_id, action_key, path, end_point }.
## Passive actions are intentionally excluded because TurnExecutionCore schedules
## them automatically; they are not player/AI planning choices.
static func get_legal_actions(game_state: Dictionary, unit_id: int) -> Array:
	var found: Dictionary = TurnExecutionCore.find_unit_by_id(game_state, unit_id)
	if found.is_empty():
		return []
	var unit: Dictionary = found.unit
	var group: Dictionary = found.group
	if int(unit.get("health", 0)) <= 0:
		return []

	var def_path: String = str(unit.get("def_path", ""))
	if def_path.is_empty():
		return []
	var def: Resource = load(def_path) as Resource
	if def == null:
		return []

	var action_keys: Array = []
	if def is UnitDefinition:
		action_keys.append_array(def.get_move_action_keys_resolved())
		action_keys.append_array(def.get_ability_action_keys_resolved())
	else:
		var def_dict: Dictionary = TurnExecutionCore.get_unit_def(def_path)
		action_keys.append_array(def_dict.get("move_action_keys", []))
		action_keys.append_array(def_dict.get("ability_action_keys", []))

	var result: Array = []
	for raw_key in action_keys:
		var action_key := str(raw_key)
		for candidate in _candidate_actions_for_key(unit, action_key):
			var validation: Dictionary = ServerTurnExecutor.validate_action(game_state, candidate, str(group.get("name", "")))
			if bool(validation.get("valid", false)):
				result.append(candidate)
	return result


static func _candidate_actions_for_key(unit: Dictionary, action_key: String) -> Array:
	var config: Dictionary = Actions.get_action_config(action_key)
	if config.is_empty():
		return []
	var cell: Array = unit.get("cell", [0, 0])
	if cell.size() < 2:
		return []
	var q := int(cell[0])
	var r := int(cell[1])
	var unit_id := int(unit.get("unit_id", -1))
	var action_type := str(config.get("type", ""))
	var pattern := str(config.get("pattern", ""))

	if pattern in ["self", "area_adjacent"] or (int(config.get("min_range", -1)) == 0 and int(config.get("max_range", -1)) == 0):
		return [_make_action(unit_id, action_key, [], Vector2i(q, r))]

	if pattern == "self_or_adjacent":
		var options: Array = [_make_action(unit_id, action_key, [], Vector2i(q, r))]
		for target in HexGrid.get_adjacent_hexes(q, r):
			options.append(_make_action(unit_id, action_key, [], target))
		return options

	if action_type == "spawn":
		return [_make_action(unit_id, action_key, [], Vector2i(q, r))]

	var min_range := int(config.get("min_range", -1))
	var max_range := int(config.get("max_range", -1))
	if min_range < 0 or max_range < min_range:
		return []

	var result: Array = []
	for distance in range(min_range, max_range + 1):
		for target in HexGrid.get_hexes_at_distance(q, r, distance):
			var path: Array = []
			if action_type in TurnExecutionCore.MOVE_TYPES:
				for step in HexGrid.build_path_to(q, r, target.x, target.y):
					path.append([int(step.x), int(step.y)])
			result.append(_make_action(unit_id, action_key, path, target))
	return result


static func _make_action(unit_id: int, action_key: String, path: Array, target: Vector2i) -> Dictionary:
	return {
		"unit_id": unit_id,
		"action_key": action_key,
		"path": path,
		"end_point": [target.x, target.y],
	}
