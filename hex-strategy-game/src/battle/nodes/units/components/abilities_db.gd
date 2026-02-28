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
		var config: Dictionary = Actions.get_action_config(action_key)
		if not _has_required_group_resources(config):
			return []
		if Actions.get_action_type(action_key) == "extract" and not _can_extract_from_current_cell(action_key):
			return []
		var power: int = int(config.get("energy_consumption", 0))
		if power > 0 and unit.max_energy > 0 and unit.energy < power:
			return []
		var defs_arr: Array = Actions.get_ability_definitions_for_action(action_key)
		for def in defs_arr:
			var ac: ActionInstance = def.to_action_instance(unit) as ActionInstance
			result.append({"ac": ac, "is_move": false})
		return _filter_acs_and_wrap(result)
	return []

func _can_extract_from_current_cell(action_key: String) -> bool:
	var cell: Vector2 = unit.cell
	var key := HexGrid.get_cell_key(int(cell.x), int(cell.y))
	if not Navigation.grid.has(key):
		return false
	var tile: Dictionary = Navigation.grid[key]
	if int(tile.get("resource_amount", 0)) <= 0:
		return false
	var config: Dictionary = Actions.get_action_config(action_key)
	var allowed_types = config.get("allowed_resource_types", [])
	if allowed_types is Array and not allowed_types.is_empty():
		var resource_type: String = str(tile.get("resource_type", ""))
		return resource_type in allowed_types
	return true

func _has_required_group_resources(config: Dictionary) -> bool:
	var required_type: String = str(config.get("required_group_resource_type", ""))
	var required_amount: int = int(config.get("required_group_resource_amount", 0))
	if required_type.is_empty() or required_amount <= 0:
		return true
	var inventory: Dictionary = _get_group_resource_inventory()
	return int(inventory.get(required_type, 0)) >= required_amount

func _get_group_resource_inventory() -> Dictionary:
	var group_node: Node = unit.get_parent()
	if group_node == null or not group_node.has_meta("resource_inventory"):
		return {}
	var inv = group_node.get_meta("resource_inventory")
	if not (inv is Dictionary):
		return {}
	return inv

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
