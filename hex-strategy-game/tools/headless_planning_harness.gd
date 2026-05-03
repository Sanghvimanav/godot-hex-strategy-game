extends RefCounted
## Builds a minimal battle subtree (hex_map + units) for headless LLM snapshot / metrics without GUI or live API.
## Parent layout matches battle.tscn: hex_map and units are siblings under one root.

const HEX_MAP_SCRIPT := preload("res://src/maps/hex_map.gd")
const _LlmPlanningSnapshot := preload("res://src/llm_ai/llm_planning_snapshot.gd")


static func build_battle_root() -> Node2D:
	var root := Node2D.new()
	root.name = "headless_planning_harness"

	var hex_map := Node2D.new()
	hex_map.name = "hex_map"
	hex_map.set_script(HEX_MAP_SCRIPT)
	hex_map.hex_radius = 5
	hex_map.spacing = 14
	hex_map.tile_radius = 14.0

	var units := UnitsContainer.new()
	units.name = "units"

	# Units must exist before hex_map._ready (hex_map looks up sibling "units" for Navigation).
	root.add_child(units)
	root.add_child(hex_map)
	return root


## Groups that need an LLM planning snapshot (primary AI groups + drill `llm_ai` groups).
static func list_llm_perspectives(units: UnitsContainer) -> Array[String]:
	var out: Array[String] = []
	for g in units.groups:
		var gn: String = str(g.name)
		if gn in units.ai_group_names:
			out.append(gn)
	for gname in units.drill_scripted_groups:
		if str(units.drill_scripted_groups[gname]) == "llm_ai":
			out.append(str(gname))
	return out


static func snapshot_for_group(units: UnitsContainer, group_name: String) -> Dictionary:
	var saved: Array[String] = units.ai_group_names.duplicate()
	units.ai_group_names.clear()
	units.ai_group_names.append(group_name)
	var snap: Dictionary = _LlmPlanningSnapshot.build_for_llm(units)
	units.ai_group_names = saved
	return snap


static func metrics_from_snapshot(snap: Dictionary) -> Dictionary:
	var ai_units: Array = snap.get("ai_units", []) as Array
	var per_unit: Array = []
	for u in ai_units:
		if not (u is Dictionary):
			continue
		var ud: Dictionary = u
		var opts: Array = ud.get("legal_options", []) as Array
		var min_incoming: int = 999999
		var max_incoming: int = 0
		for opt in opts:
			if not (opt is Dictionary):
				continue
			var od: Dictionary = opt
			var inc: int = 0
			if od.has("pred_damage_at_end"):
				inc = int(od.get("pred_damage_at_end", 0))
			else:
				inc = int(od.get("incoming_damage_if_enemies_hold_and_shoot_end", 0))
			min_incoming = mini(min_incoming, inc)
			max_incoming = maxi(max_incoming, inc)
		if min_incoming == 999999:
			min_incoming = 0
		per_unit.append({
			"unit_id": int(ud.get("unit_id", 0)),
			"name": str(ud.get("name", "")),
			"cell": ud.get("cell", []),
			"min_incoming_damage_across_legal_options": min_incoming,
			"max_incoming_damage_across_legal_options": max_incoming,
		})
	return {
		"scenario_id": snap.get("scenario_id", ""),
		"turn": snap.get("turn", 0),
		"ai_units": per_unit,
		"enemy_reaction_candidate_count": (snap.get("enemy_reaction_candidates", []) as Array).size(),
	}


## Apply scenario, wait for nodes, return units. Caller must add `root` to the tree and free it when done.
static func setup_scenario_on_tree(root: Node2D, scenario_id: String) -> UnitsContainer:
	Scenarios.select_scenario(scenario_id)
	var scenario: Dictionary = Scenarios.get_selected_scenario()
	var units: UnitsContainer = root.get_node("units") as UnitsContainer
	units.apply_scenario(scenario)
	units.turn_number = 1
	return units
