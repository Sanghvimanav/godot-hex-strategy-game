extends Node

var unit: Unit

func _filter_acs(acs: Array) -> Array:
	return acs

func get_attack_paths() -> Array:
	var defs: Array = unit.def.get_ability_definitions_resolved()
	return _filter_acs(defs.map(func (def): return def.to_action_instance(unit) as ActionInstance))

func get_move_paths() -> Array:
	var defs: Array = unit.def.get_move_definitions_resolved()
	return _filter_acs(defs.map(func (def): return def.to_action_instance(unit) as ActionInstance))

## Returns Array of {ac: ActionInstance, is_move: bool} for a single action key.
func get_options_for_action_key(action_key: String) -> Array:
	var result: Array = []
	if action_key in unit.def.move_action_keys:
		var defs_arr: Array = Actions.get_move_definitions_for_action(action_key)
		for def in defs_arr:
			var ac: ActionInstance = def.to_action_instance(unit) as ActionInstance
			result.append({"ac": ac, "is_move": true})
		return _filter_acs_and_wrap(result)
	if action_key in unit.def.ability_action_keys:
		if Actions.get_action_type(action_key) == "extract" and not _can_extract_from_current_cell():
			return []
		var config: Dictionary = Actions.get_action_config(action_key)
		var power: int = int(config.get("energy_consumption", 0))
		if power > 0 and unit.max_energy > 0 and unit.energy <= 0:
			return []
		var defs_arr: Array = Actions.get_ability_definitions_for_action(action_key)
		for def in defs_arr:
			var ac: ActionInstance = def.to_action_instance(unit) as ActionInstance
			result.append({"ac": ac, "is_move": false})
		return _filter_acs_and_wrap(result)
	return []

func _can_extract_from_current_cell() -> bool:
	var cell: Vector2 = unit.cell
	var key := HexGrid.get_cell_key(int(cell.x), int(cell.y))
	if not Navigation.grid.has(key):
		return false
	var tile: Dictionary = Navigation.grid[key]
	return int(tile.get("resource_amount", 0)) > 0

func _filter_acs_and_wrap(entries: Array) -> Array:
	var acs: Array = []
	for e in entries:
		acs.append(e.ac)
	var filtered: Array = _filter_acs(acs)
	var is_move_map: Dictionary = {}
	for e in entries:
		is_move_map[e.ac] = e.is_move
	var out: Array = []
	for ac in filtered:
		out.append({"ac": ac, "is_move": is_move_map.get(ac, false)})
	return out
