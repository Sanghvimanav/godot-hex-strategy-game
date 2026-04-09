extends RefCounted
class_name LlmUnitCapabilities
## Builds a compact JSON-serializable roster of unit types and their action keys for LLM prompts (post-game, etc.).


static func _action_entry(key: String) -> Dictionary:
	var cfg: Dictionary = Actions.get_action_config(key)
	return {
		"key": key,
		"type": str(cfg.get("type", "")),
		"name": str(cfg.get("name", key)),
	}


static func _unit_entry(def: UnitDefinition, def_path: String) -> Dictionary:
	var move_keys: Array = def.get_move_action_keys_resolved()
	var ability_keys: Array = def.get_ability_action_keys_resolved()
	var passive_keys: Array = def.passive_action_keys.duplicate()
	var moves: Array = []
	var abilities: Array = []
	var passives: Array = []
	for k in move_keys:
		moves.append(_action_entry(str(k)))
	for k in ability_keys:
		abilities.append(_action_entry(str(k)))
	for k in passive_keys:
		passives.append(_action_entry(str(k)))
	return {
		"name": def.name,
		"def_path": def_path,
		"description": def.description.strip_edges(),
		"moves": moves,
		"abilities": abilities,
		"passives": passives,
	}


## Sorted by unit name; each entry lists move vs ability vs passive keys with action types from Actions (e.g. "move", "ability").
static func build_unit_action_roster() -> Array:
	var out: Array = []
	var root := "res://src/unit/definitions"
	var dir := DirAccess.open(root)
	if dir == null:
		push_warning("LlmUnitCapabilities: cannot open %s" % root)
		return out
	dir.list_dir_begin()
	var fn := dir.get_next()
	while fn != "":
		if not dir.current_is_dir() and fn.ends_with(".tres"):
			var path: String = root.path_join(fn)
			var res: Resource = load(path)
			if res is UnitDefinition:
				out.append(_unit_entry(res as UnitDefinition, path))
		fn = dir.get_next()
	dir.list_dir_end()
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return str(a.get("name", "")) < str(b.get("name", ""))
	)
	return out
