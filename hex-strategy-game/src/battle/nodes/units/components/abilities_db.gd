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
	var availability: Dictionary = get_action_availability(action_key)
	var options = availability.get("options", [])
	return options if options is Array else []

## Returns {available: bool, options: Array, reason: String} for one action key.
func get_action_availability(action_key: String) -> Dictionary:
	if unit == null or unit.def == null:
		return {
			"available": false,
			"options": [],
			"reason": "No unit selected",
		}
	var result: Array = []
	if action_key in unit.def.move_action_keys:
		var defs_arr: Array = Actions.get_move_definitions_for_action(action_key)
		for def in defs_arr:
			var ac: ActionInstance = def.to_action_instance(unit) as ActionInstance
			result.append({"ac": ac, "is_move": true})
		var move_options: Array = _filter_acs_and_wrap(result)
		return {
			"available": not move_options.is_empty(),
			"options": move_options,
			"reason": "No valid targets" if move_options.is_empty() else "",
		}
	elif action_key in unit.def.ability_action_keys:
		var reason: String = _get_ability_unavailability_reason(action_key)
		if not reason.is_empty():
			return {
				"available": false,
				"options": [],
				"reason": reason,
			}
		var defs_arr: Array = Actions.get_ability_definitions_for_action(action_key)
		for def in defs_arr:
			var ac: ActionInstance = def.to_action_instance(unit) as ActionInstance
			result.append({"ac": ac, "is_move": false})
		var ability_options: Array = _filter_acs_and_wrap(result)
		return {
			"available": not ability_options.is_empty(),
			"options": ability_options,
			"reason": "No valid targets" if ability_options.is_empty() else "",
		}
	return {
		"available": false,
		"options": [],
		"reason": "Unknown action",
	}

func _get_ability_unavailability_reason(action_key: String) -> String:
	var config: Dictionary = Actions.get_action_config(action_key)
	if not _has_required_group_resources(config):
		return _format_required_group_resources_reason(config)
	if Actions.get_action_type(action_key) == "extract" and not _can_extract_from_current_cell(action_key):
		return _format_extract_unavailability_reason(config)
	var power: int = int(config.get("energy_consumption", 0))
	if power > 0 and unit.max_energy > 0 and unit.energy < power:
		return "Requires %d energy (%d/%d)" % [power, unit.energy, unit.max_energy]
	return ""

func _format_required_group_resources_reason(config: Dictionary) -> String:
	var required_type: String = str(config.get("required_group_resource_type", "resource"))
	var required_amount: int = int(config.get("required_group_resource_amount", 0))
	if required_amount <= 0:
		return "Insufficient group resources"
	return "Requires %d %s" % [required_amount, required_type]

func _format_extract_unavailability_reason(config: Dictionary) -> String:
	var cell: Vector2 = unit.cell
	var key := HexGrid.get_cell_key(int(cell.x), int(cell.y))
	if not Navigation.grid.has(key):
		return "No resource on this tile"
	var tile: Dictionary = Navigation.grid[key]
	if int(tile.get("resource_amount", 0)) <= 0:
		return "No resource left on this tile"
	var allowed_types = config.get("allowed_resource_types", [])
	if allowed_types is Array and not allowed_types.is_empty():
		var resource_type: String = str(tile.get("resource_type", ""))
		if resource_type not in allowed_types:
			return "Requires %s resource on this tile" % _join_resource_types(allowed_types)
	return "Unavailable on this tile"

func _join_resource_types(resource_types: Array) -> String:
	var names: Array[String] = []
	for resource_type in resource_types:
		names.append(str(resource_type))
	return ", ".join(names)

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
	var inv: Dictionary = _get_group_resource_inventory()
	return TurnExecutionCore.has_required_group_resources({"resources": inv}, config)

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
