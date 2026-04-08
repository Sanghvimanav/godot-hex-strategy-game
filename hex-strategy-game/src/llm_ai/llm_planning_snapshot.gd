extends RefCounted
class_name LlmPlanningSnapshot
## Builds JSON-safe snapshot + side table units._llm_option_tables[unit_id] -> Array of {ac, is_move}.

const PlanningAI = preload("res://src/battle/ai/planning_ai.gd")
const _LearningsIngest = preload("res://src/llm_ai/llm_learnings_ingest.gd")
const _RecentTurns = preload("res://src/llm_ai/llm_planning_recent_turns.gd")
const _RulesCatalog = preload("res://src/llm_ai/llm_planning_rules_catalog.gd")


static func _stable_unit_id(u: Unit) -> int:
	if u == null:
		return 0
	if u.has_meta("unit_id"):
		return int(u.get_meta("unit_id"))
	return u.get_instance_id()


## Argument is a UnitsContainer; typed as Node to avoid a class_name cycle with units.gd.
static func build_for_llm(units: Node) -> Dictionary:
	units._llm_option_tables.clear()
	var hex_parent: Node = units.get_parent()
	var hex_map: Node = hex_parent.get_node_or_null("hex_map") if hex_parent else null
	var map_bounds: Dictionary = {}
	var board_hex_radius: int = 0
	if hex_map != null and hex_map.has_method("get_map_bounds_for_llm"):
		map_bounds = hex_map.get_map_bounds_for_llm()
		board_hex_radius = int(map_bounds.get("hex_radius", 0))
	var ai_visible: Dictionary = {}
	if hex_map != null and hex_map.has_method("compute_visible_cell_keys_for_ai_groups"):
		ai_visible = hex_map.compute_visible_cell_keys_for_ai_groups(units)

	var rules_stub := (
		"Turn: planning then simultaneous execution. Win by eliminating enemy units. "
		+ "Coordinates are axial (q,r) as in each unit cell and legal option path/end. "
		+ "Stun may block actions. Energy/costs per unit definition. "
		+ "action_definitions lists every action key (range, energy, pattern, damage, spawn costs, etc.). "
		+ "unit_type_definitions lists each unit type, a short description, and which action keys it uses; *_resolved includes default Rest when applicable."
	)

	var enemies_visible: Array = []
	for u in units.get_all_units():
		if not (is_instance_valid(u) and u is Unit and u.is_active):
			continue
		var gname: String = u.get_parent().name if u.get_parent() else ""
		if gname in units.ai_group_names:
			continue
		var cell_key := HexGrid.get_cell_key(int(u.cell.x), int(u.cell.y))
		var vis: bool = ai_visible.is_empty() or bool(ai_visible.get(cell_key, false))
		if not vis:
			continue
		enemies_visible.append({
			"unit_id": _stable_unit_id(u),
			"cell": [int(u.cell.x), int(u.cell.y)],
			"health": u.health,
			"max_health": u.max_health,
			"group": gname,
			"def": u.def.resource_path if u.def else "",
			"name": u.def.name if u.def else "unit",
		})

	var ai_units: Array = []
	for u in units.get_active_units():
		if not (is_instance_valid(u) and u is Unit and u.is_active):
			continue
		var gname: String = u.get_parent().name if u.get_parent() else ""
		if gname not in units.ai_group_names:
			continue
		var uid := _stable_unit_id(u)
		var opts: Array = PlanningAI._collect_all_options(u)
		units._llm_option_tables[uid] = opts
		var legal: Array = []
		for i in range(opts.size()):
			var e: Dictionary = opts[i]
			var ac: ActionInstance = e.get("ac")
			var is_move: bool = bool(e.get("is_move", false))
			if ac == null or ac.definition == null:
				continue
			var path_arr: Array = []
			for p in ac.path:
				path_arr.append([int(p.x), int(p.y)])
			var ex := int(ac.end_point.x)
			var ey := int(ac.end_point.y)
			var dist0 := HexGrid.hex_distance(0, 0, ex, ey)
			var opt_dict: Dictionary = {
				"i": i,
				"action_key": str(ac.definition.action_key),
				"path": path_arr,
				"end": [ex, ey],
				"is_move": is_move,
				## Hex distance of this option's end cell from map origin (0,0); matches map_bounds.hex_radius on the outer ring.
				"dist_from_origin": dist0,
			}
			if board_hex_radius > 0:
				opt_dict["dist_from_map_edge"] = board_hex_radius - dist0
			## Same order as visible_enemy_units; hex distance from this option's end cell to each visible enemy.
			var dists_enemies: Array = []
			for enemy_entry in enemies_visible:
				if typeof(enemy_entry) != TYPE_DICTIONARY:
					continue
				var ed: Dictionary = enemy_entry
				var ec: Array = ed.get("cell", []) as Array
				var eq: int = int(ec[0]) if ec.size() >= 1 else 0
				var er: int = int(ec[1]) if ec.size() >= 2 else 0
				dists_enemies.append({
					"unit_id": int(ed.get("unit_id", 0)),
					"hex_dist": HexGrid.hex_distance(ex, ey, eq, er),
				})
			opt_dict["distances_to_visible_enemies"] = dists_enemies
			legal.append(opt_dict)
		ai_units.append({
			"unit_id": uid,
			"cell": [int(u.cell.x), int(u.cell.y)],
			"health": u.health,
			"max_health": u.max_health,
			"energy": u.energy,
			"max_energy": u.max_energy,
			"group": gname,
			"def": u.def.resource_path if u.def else "",
			"name": u.def.name if u.def else "unit",
			"legal_options": legal,
		})

	return {
		"rules_digest": rules_stub,
		"rules_version": "v2_catalog",
		"action_definitions": _RulesCatalog.build_action_definitions(),
		"unit_type_definitions": _RulesCatalog.build_unit_type_definitions(),
		"scenario_id": Scenarios.selected_scenario_id,
		"turn": units.turn_number,
		"visible_enemy_units": enemies_visible,
		"ai_units": ai_units,
		"prior_learnings": _LearningsIngest.build_prompt_block_for_planner(map_bounds),
		"map_bounds": map_bounds,
		"recent_turns": _RecentTurns.build_for_llm(units),
	}
