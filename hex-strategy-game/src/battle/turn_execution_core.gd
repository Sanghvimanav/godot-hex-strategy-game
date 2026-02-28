extends RefCounted
class_name TurnExecutionCore
## Shared turn execution logic for single-player and multiplayer.
## Operates on dictionary game state. Server delegates here; client can use get_damage_cells_for_config for consistent targeting.

const MOVE_TYPES: Array[String] = ["fast move", "move", "slow move"]
const ABILITY_TYPES: Array[String] = ["fast ability", "ability", "slow ability"]


static func find_unit_by_id(game_state: Dictionary, unit_id: int) -> Dictionary:
	for group in game_state.get("groups", []):
		for u in group.get("units", []):
			if u.get("unit_id", -1) == unit_id:
				return { "unit": u, "group": group }
	return {}


static func get_units_at_cell(game_state: Dictionary, cell: Vector2i) -> Array:
	var q := cell.x
	var r := cell.y
	var result: Array = []
	for group in game_state.get("groups", []):
		for u in group.get("units", []):
			if u.get("health", 0) > 0:
				var uc: Array = u.get("cell", [0, 0])
				if uc.size() >= 2 and int(uc[0]) == q and int(uc[1]) == r:
					result.append({ "unit": u, "group": group })
	return result


static func get_unit_def(def_path: String) -> Dictionary:
	var def: Resource = load(def_path) as Resource
	var move_keys = def.get("move_action_keys") if def else null
	if def == null or move_keys == null:
		return {}
	var ab_keys = def.get("ability_action_keys")
	var pass_keys = def.get("passive_action_keys")
	var max_h = def.get("max_health")
	var max_e = def.get("max_energy")
	var start_e = def.get("start_energy")
	return {
		move_action_keys = move_keys,
		ability_action_keys = ab_keys if ab_keys != null else [],
		passive_action_keys = pass_keys if pass_keys != null else [],
		max_health = int(max_h) if max_h != null and int(max_h) > 0 else 2,
		max_energy = int(max_e) if max_e != null else 0,
		start_energy = int(start_e) if start_e != null and start_e >= 0 else (int(max_e) if max_e != null else 0)
	}


static func _cell_q(v: Variant) -> int:
	if v is Array and v.size() >= 1:
		return int(v[0])
	if v is Vector2 or v is Vector2i:
		return int(v.x)
	return 0


static func _cell_r(v: Variant) -> int:
	if v is Array and v.size() >= 2:
		return int(v[1])
	if v is Vector2 or v is Vector2i:
		return int(v.y)
	return 0


## Returns list of cells (Vector2i) that an ability affects for damage. Shared by server and client.
## path_array: Array of [q,r] or Vector2; end_point: [q,r] or Vector2.
static func get_damage_cells_for_config(attacker_q: int, attacker_r: int, path_array: Array, end_point: Variant, config: Dictionary) -> Array:
	var pattern: String = config.get("pattern", "")
	if pattern == "self":
		return [Vector2i(attacker_q, attacker_r)]
	if pattern == "ray":
		var ep_q: int = _cell_q(end_point)
		var ep_r: int = _cell_r(end_point)
		var path_to_target: Array = HexGrid.build_path_to(attacker_q, attacker_r, ep_q, ep_r)
		var out: Array = []
		for p in path_to_target:
			out.append(Vector2i(int(p.x), int(p.y)))
		return out
	if pattern == "target":
		return [Vector2i(_cell_q(end_point), _cell_r(end_point))]
	if pattern == "area_adjacent":
		var out: Array = [Vector2i(attacker_q, attacker_r)]
		for d in HexGrid.AXIAL_DIRECTIONS:
			out.append(Vector2i(attacker_q + d.x, attacker_r + d.y))
		return out
	if pattern == "self_or_adjacent":
		var ep_q: int = _cell_q(end_point)
		var ep_r: int = _cell_r(end_point)
		return [Vector2i(attacker_q + ep_q, attacker_r + ep_r)]
	var cells: Array = []
	for p in path_array:
		cells.append(Vector2i(_cell_q(p), _cell_r(p)))
	cells.append(Vector2i(_cell_q(end_point), _cell_r(end_point)))
	return cells


static func get_action_type(action_key: String) -> String:
	return Actions.get_action_type(action_key)

## Depletes finite resource at cell if game_state has tile_resources.
## Supports value form: key -> int, and dictionary form: key -> { amount = int, ... }.
static func _deplete_tile_resource(game_state: Dictionary, cell: Variant, amount: int) -> int:
	if amount <= 0:
		return 0
	var tile_resources = game_state.get("tile_resources")
	if not (tile_resources is Dictionary):
		return 0
	var q: int = _cell_q(cell)
	var r: int = _cell_r(cell)
	var key := HexGrid.get_cell_key(q, r)
	if not tile_resources.has(key):
		return 0
	var entry = tile_resources[key]
	var current_amount: int = 0
	if entry is Dictionary:
		current_amount = int(entry.get("amount", entry.get("resource_amount", 0)))
	else:
		current_amount = int(entry)
	if current_amount <= 0:
		return 0
	var consumed: int = mini(current_amount, amount)
	var next_amount: int = current_amount - consumed
	if entry is Dictionary:
		entry["amount"] = next_amount
		if entry.has("resource_amount"):
			entry["resource_amount"] = next_amount
		tile_resources[key] = entry
	else:
		tile_resources[key] = next_amount
	game_state["tile_resources"] = tile_resources
	return consumed

static func _extract_tile_resource(game_state: Dictionary, cell: Variant, amount: int) -> Dictionary:
	var tile_resources = game_state.get("tile_resources")
	if not (tile_resources is Dictionary):
		return { consumed = 0, resource_type = "" }
	var key := HexGrid.get_cell_key(_cell_q(cell), _cell_r(cell))
	var entry = tile_resources.get(key)
	var resource_type: String = ""
	if entry is Dictionary:
		resource_type = str(entry.get("resource_type", ""))
	var consumed: int = _deplete_tile_resource(game_state, cell, amount)
	return { consumed = consumed, resource_type = resource_type }

static func _add_group_resource(group: Dictionary, resource_type: String, amount: int) -> void:
	if amount <= 0:
		return
	var safe_type: String = resource_type if not resource_type.is_empty() else "resource"
	var resources = group.get("resources", {})
	if not (resources is Dictionary):
		resources = {}
	resources[safe_type] = int(resources.get(safe_type, 0)) + amount
	group["resources"] = resources


static func execute_turn(game_state: Dictionary, player_actions: Dictionary) -> Dictionary:
	var recording: Dictionary = { actions = [], died_ids = [], summary = [] }
	var damage_by_id: Dictionary = {}
	var applied_damage_by_id: Dictionary = {}

	for action_type in Actions.ACTION_ORDER:
		var entries: Array = []
		for group in game_state.get("groups", []):
			var gname: String = group.get("name", "")
			# Process all groups that have actions (SP includes AI; MP only has human groups)
			for action in player_actions.get(gname, []):
				var found = find_unit_by_id(game_state, action.get("unit_id", -1))
				if found.is_empty():
					continue
				if get_action_type(str(action.get("action_key", ""))) != action_type:
					continue
				entries.append({ "unit": found.unit, "action": action, "group": group })

		# Add passive abilities (e.g. attack_passive) so server matches single-player TurnExecutor:
		# each unit's passive_action_keys become implicit actions in the appropriate ability phase.
		if action_type in ABILITY_TYPES:
			for group in game_state.get("groups", []):
				# Include AI groups for passive abilities (SP)
				for unit in group.get("units", []):
					if unit.get("health", 0) <= 0:
						continue
					var def_path: String = unit.get("def_path", "")
					if def_path.is_empty():
						continue
					var def_dict: Dictionary = get_unit_def(def_path)
					var passive_keys: Array = def_dict.get("passive_action_keys", [])
					for pkey in passive_keys:
						var ptype: String = get_action_type(str(pkey))
						if ptype != action_type:
							continue
						var p_action: Dictionary = {
							"unit_id": unit.get("unit_id", -1),
							"action_key": pkey,
							"path": [],
							"end_point": [0, 0],
						}
						entries.append({ "unit": unit, "action": p_action, "group": group })

		if action_type in MOVE_TYPES:
			for entry in entries:
				var unit: Dictionary = entry.unit
				if unit.get("health", 0) <= 0:
					continue
				var action: Dictionary = entry.action
				var path: Array = action.get("path", []).duplicate()
				path.append(action.get("end_point", [0, 0]))
				if path.size() >= 2:
					var from_cell: Array = unit.get("cell", [0, 0]).duplicate()
					var target: Array = path[path.size() - 1]
					unit["cell"] = [int(target[0]), int(target[1])]
					recording.actions.append({
						type = "move",
						unit_id = unit.get("unit_id", -1),
						from_cell = from_cell,
						path = path
					})
		elif action_type == "extract":
			for entry in entries:
				var unit: Dictionary = entry.unit
				if unit.get("health", 0) <= 0:
					continue
				var action: Dictionary = entry.action
				var action_key: String = str(action.get("action_key", ""))
				var config: Dictionary = Actions.get_action_config(action_key)
				if config.is_empty():
					continue
				var extract_amount: int = maxi(1, int(config.get("tile_resource_depletion", 1)))
				var unit_cell: Array = unit.get("cell", [0, 0])
				var extraction: Dictionary = _extract_tile_resource(game_state, unit_cell, extract_amount)
				var consumed: int = int(extraction.get("consumed", 0))
				var resource_type: String = str(extraction.get("resource_type", ""))
				if consumed > 0:
					_add_group_resource(entry.group, resource_type, consumed)
				recording.actions.append({
					type = "extract",
					unit_id = unit.get("unit_id", -1),
					action_key = action_key,
					cell = [int(unit_cell[0]), int(unit_cell[1])],
					resource_type = resource_type,
					amount = consumed
				})
		elif action_type in ABILITY_TYPES:
			for entry in entries:
				var unit: Dictionary = entry.unit
				if unit.get("health", 0) <= 0:
					continue
				var action: Dictionary = entry.action
				var config: Dictionary = Actions.get_action_config(str(action.get("action_key", "")))
				if config.is_empty():
					continue
				var ec: int = int(config.get("energy_consumption", 0))
				if ec > 0 and unit.get("max_energy", 0) > 0:
					unit["energy"] = maxi(0, unit.get("energy", 0) - ec)
				elif ec < 0:
					unit["energy"] = mini(unit.get("max_energy", 0), unit.get("energy", 0) + absi(ec))
				var action_key: String = str(action.get("action_key", ""))
				var uc: Array = unit.get("cell", [0, 0])
				var uq: int = int(uc[0])
				var ur: int = int(uc[1])
				var path_arr: Array = action.get("path", [])
				var end_pt = action.get("end_point", [0, 0])
				var target_cells: Array = get_damage_cells_for_config(uq, ur, path_arr, end_pt, config)
				var tile_resource_depletion: int = int(config.get("tile_resource_depletion", 0))
				if tile_resource_depletion > 0:
					for cell in target_cells:
						_deplete_tile_resource(game_state, cell, tile_resource_depletion)
				var attacker_group_name: String = entry.group.get("name", "")
				if action_key in ["heal_adjacent", "support_adjacent", "resupply_adjacent"]:
					var heal_amount: int = int(config.get("heal_amount", 0))
					var recharge: int = int(config.get("recharge", 0))
					for cell in target_cells:
						for o in get_units_at_cell(game_state, cell):
							if o.group.get("name", "") != attacker_group_name:
								continue
							var target_u: Dictionary = o.unit
							if target_u.get("health", 0) <= 0:
								continue
							if heal_amount > 0:
								var max_h: int = target_u.get("max_health", 2)
								target_u["health"] = mini(target_u.get("health", max_h) + heal_amount, max_h)
							if recharge > 0 and target_u.get("max_energy", 0) > 0:
								target_u["energy"] = mini(target_u.get("energy", 0) + recharge, target_u.get("max_energy", 0))
				else:
					if config.has("area_of_effect"):
						var aoe_cells: Array = HexGrid.get_aoe_tiles(Vector2(uq, ur), Vector2(_cell_q(end_pt), _cell_r(end_pt)), config.area_of_effect)
						for c in aoe_cells:
							target_cells.append(Vector2i(int(c.x), int(c.y)))
					var damage_amount: int = int(config.get("damage", 1))
					for cell in target_cells:
						for o in get_units_at_cell(game_state, cell):
							if o.unit == unit:
								continue
							if o.group.get("name", "") == attacker_group_name:
								continue
							var uid: int = o.unit.get("unit_id", -1)
							damage_by_id[uid] = damage_by_id.get(uid, 0) + damage_amount
					if config.get("self_damage", false):
						var uid: int = unit.get("unit_id", -1)
						damage_by_id[uid] = damage_by_id.get(uid, 0) + int(config.get("self_damage_amount", 999))
				recording.actions.append({
					type = action_type,
					unit_id = unit.get("unit_id", -1),
					action_key = action.get("action_key", ""),
					ac = action
				})
			for uid in damage_by_id:
				var total: int = damage_by_id[uid]
				var applied: int = applied_damage_by_id.get(uid, 0)
				var to_apply: int = total - applied
				if to_apply <= 0:
					continue
				var found = find_unit_by_id(game_state, uid)
				if found.is_empty():
					continue
				var u: Dictionary = found.unit
				u["health"] = maxi(0, u.get("health", 2) - to_apply)
				applied_damage_by_id[uid] = total
				if u["health"] <= 0:
					recording.died_ids.append(uid)

	for group in game_state.get("groups", []):
		var units: Array = group.get("units", [])
		var died: Array = recording.get("died_ids", [])
		group["units"] = units.filter(func(u): return u.get("unit_id", -1) not in died)

	return recording


static func check_win_condition(game_state: Dictionary) -> String:
	var alive_human: Array = []
	for group in game_state.get("groups", []):
		if group.get("ai", false):
			continue
		var has_alive: bool = false
		for u in group.get("units", []):
			if u.get("health", 0) > 0:
				has_alive = true
				break
		if has_alive:
			alive_human.append(group.get("name", ""))
	if alive_human.size() <= 1:
		return alive_human[0] if alive_human.size() == 1 else ""
	return ""
