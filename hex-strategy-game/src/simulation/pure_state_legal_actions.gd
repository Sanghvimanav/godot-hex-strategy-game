extends RefCounted
class_name PureStateLegalActions
## Data-only legal action enumeration for search / neural AI.
##
## Generates plain Dictionary actions directly from dictionary game state, then
## validates each candidate through ServerTurnExecutor so multiplayer validation
## remains the primary source of truth for action legality.

const ServerTurnExecutor = preload("res://src/server/server_turn_executor.gd")
const TurnExecutionCore = preload("res://src/battle/turn_execution_core.gd")


## Returns every currently executable planned action for unit_id as plain dictionaries:
## { unit_id, action_key, path, end_point }.
## Passive actions are intentionally excluded because TurnExecutionCore schedules
## them automatically; they are not player/AI planning choices.
##
## If game_state includes hex_radius, candidate paths/targets are also constrained
## to that board radius. States without geometry remain compatible with existing
## server/test dictionaries and rely on ServerTurnExecutor validation alone.
static func get_legal_actions(game_state: Dictionary, unit_id: int) -> Array:
	var found: Dictionary = TurnExecutionCore.find_unit_by_id(game_state, unit_id)
	if found.is_empty():
		return []
	var unit: Dictionary = found.unit
	var group: Dictionary = found.group
	if int(unit.get("health", 0)) <= 0 or _unit_has_active_stun(unit):
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
			if not _candidate_within_board(game_state, candidate):
				continue
			var validation: Dictionary = ServerTurnExecutor.validate_action(game_state, candidate, str(group.get("name", "")))
			if bool(validation.get("valid", false)):
				result.append(candidate)
	return result


static func _unit_has_active_stun(unit: Dictionary) -> bool:
	# Mirrors TurnExecutionCore's active-stun semantics: a newly applied stun has
	# pending_first_tick=true and does not suppress the turn on which it lands.
	for raw_effect in unit.get("effects", []):
		if not (raw_effect is Dictionary):
			continue
		var effect: Dictionary = raw_effect
		if str(effect.get("kind", "")) != "Stun":
			continue
		if int(effect.get("duration", 0)) <= 0:
			continue
		if bool(effect.get("pending_first_tick", false)):
			continue
		return true
	return false


static func _candidate_within_board(game_state: Dictionary, candidate: Dictionary) -> bool:
	if not game_state.has("hex_radius"):
		return true
	var radius := int(game_state.get("hex_radius", -1))
	if radius < 0:
		return true
	var cells: Array = candidate.get("path", []).duplicate()
	cells.append(candidate.get("end_point", [0, 0]))
	for raw_cell in cells:
		if not (raw_cell is Array) or raw_cell.size() < 2:
			return false
		if HexGrid.hex_distance(0, 0, int(raw_cell[0]), int(raw_cell[1])) > radius:
			return false
	return true


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
