extends Node

var unit: Unit

## Drop moves/abilities whose path, end, or AoE splash would leave the loaded hex map (Navigation.grid).
func _filter_acs(acs: Array) -> Array:
	if Navigation == null or Navigation.grid.is_empty():
		return acs
	var out: Array = []
	for ac in acs:
		if ac is ActionInstance and _action_instance_stays_on_map(ac):
			out.append(ac)
	return out


func _action_instance_stays_on_map(ac: ActionInstance) -> bool:
	for c in ac.full_path:
		if not Navigation.is_valid_cell(c):
			return false
	var config: Dictionary = {}
	if ac.definition != null and str(ac.definition.action_key) != "":
		config = Actions.get_action_config(ac.definition.action_key)
	var aoe: Dictionary = config.get("area_of_effect", {})
	if not aoe.is_empty():
		var from_cell: Vector2 = ac.unit.cell if ac.unit != null else Vector2.ZERO
		var aoe_cells: Array = HexGrid.get_aoe_tiles(from_cell, ac.end_point, aoe)
		for aoe_cell in aoe_cells:
			var v := Vector2(float(aoe_cell.x), float(aoe_cell.y))
			if not Navigation.is_valid_cell(v):
				return false
	return true

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
	if action_key in unit.def.get_move_action_keys_resolved():
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
	elif action_key in unit.def.get_ability_action_keys_resolved():
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
	var spawn_self_dmg: int = int(config.get("spawn_self_damage_amount", 0))
	if spawn_self_dmg > 0 and unit.health < spawn_self_dmg:
		return "Requires at least %d HP" % spawn_self_dmg
	if int(Actions.get_action_config(action_key).get("tile_resource_depletion", 0)) > 0 and not _can_extract_from_current_cell(action_key):
		return _format_extract_unavailability_reason(config)
	var power: int = int(config.get("energy_consumption", 0))
	if power > 0 and unit.max_energy > 0 and unit.energy < power:
		return "Requires %d energy (%d/%d)" % [power, unit.energy, unit.max_energy]
	return ""

func _format_required_group_resources_reason(config: Dictionary) -> String:
	var multi: Array = config.get("required_group_resources", [])
	if multi.size() > 0:
		var parts: Array[String] = []
		for req in multi:
			if not (req is Dictionary):
				continue
			var rtype: String = str(req.get("type", ""))
			var ramt: int = int(req.get("amount", 0))
			if rtype.is_empty() or ramt <= 0:
				continue
			parts.append("%d %s" % [ramt, rtype])
		if parts.is_empty():
			return "Insufficient group resources"
		return "Requires " + ", ".join(parts)
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
	var config: Dictionary = Actions.get_action_config(action_key)
	var required: int = maxi(1, int(config.get("tile_resource_depletion", 1)))
	if int(tile.get("resource_amount", 0)) < required:
		return false
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
