extends RefCounted
class_name LlmPlanningRulesCatalog
## JSON-safe action registry + unit definition summaries for LLM planning payloads.

const ActionsScript = preload("res://src/global/actions.gd")
const _DEF_DIR := "res://src/unit/definitions/"


static func json_safe(v: Variant) -> Variant:
	match typeof(v):
		TYPE_NIL:
			return null
		TYPE_BOOL, TYPE_INT, TYPE_FLOAT, TYPE_STRING:
			return v
		TYPE_STRING_NAME:
			return str(v)
		TYPE_VECTOR2, TYPE_VECTOR2I:
			return {"x": v.x, "y": v.y}
		TYPE_COLOR:
			return "#" + v.to_html(false)
		TYPE_DICTIONARY:
			var out := {}
			for k in v:
				out[str(k)] = json_safe(v[k])
			return out
		TYPE_ARRAY:
			var a: Array = []
			for item in v:
				a.append(json_safe(item))
			return a
		_:
			return str(v)


## One entry per action key: merged config from Actions.ACTION_CONFIGS (string keys, JSON-friendly values).
static func build_action_definitions() -> Array:
	var keys := ActionsScript.get_all_action_keys()
	var out: Array = []
	for action_key in keys:
		var cfg: Dictionary = ActionsScript.get_action_config(action_key)
		var flat: Dictionary = json_safe(cfg) as Dictionary
		flat["key"] = str(action_key)
		out.append(flat)
	return out


## One entry per `*.tres` in unit definitions (sorted by id).
static func build_unit_type_definitions() -> Array:
	var out: Array = []
	var dir = DirAccess.open(_DEF_DIR)
	if dir == null:
		push_warning("LlmPlanningRulesCatalog: cannot open %s" % _DEF_DIR)
		return out
	var err: Error = dir.list_dir_begin()
	if err != OK:
		push_warning("LlmPlanningRulesCatalog: list_dir_begin failed %d" % err)
		return out
	var fn := dir.get_next()
	while fn != "":
		if not dir.current_is_dir() and fn.ends_with(".tres"):
			var path_full: String = _DEF_DIR.path_join(fn)
			var res = load(path_full)
			if res is UnitDefinition:
				var def: UnitDefinition = res
				var id := fn.get_basename()
				var type_keys = UnitDefinition.Type.keys()
				var faction_keys = UnitDefinition.Faction.keys()
				var type_name: String = (
					str(type_keys[def.type]) if def.type >= 0 and def.type < type_keys.size() else str(def.type)
				)
				var faction_name: String = (
					str(faction_keys[def.faction])
					if def.faction >= 0 and def.faction < faction_keys.size() else str(def.faction)
				)
				out.append({
					"id": id,
					"resource_path": path_full,
					"name": def.name,
					"description": def.description,
					"type": type_name,
					"faction": faction_name,
					"move_action_keys": def.move_action_keys.duplicate(),
					"ability_action_keys": def.ability_action_keys.duplicate(),
					"passive_action_keys": def.passive_action_keys.duplicate(),
					"move_action_keys_resolved": def.get_move_action_keys_resolved(),
					"ability_action_keys_resolved": def.get_ability_action_keys_resolved(),
					"max_health": def.max_health,
					"max_energy": def.max_energy,
					"sight_range": def.sight_range,
					"start_energy": def.start_energy,
				})
		fn = dir.get_next()
	dir.list_dir_end()
	out.sort_custom(func(a, b): return str(a.get("id", "")) < str(b.get("id", "")))
	return out
