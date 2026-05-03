extends RefCounted
class_name LlmPlanningSnapshot
## Builds JSON-safe snapshot + side table units._llm_option_tables[unit_id] -> Array of {ac, is_move}.

const PlanningAI = preload("res://src/battle/ai/planning_ai.gd")
const TurnExecutionCore = preload("res://src/battle/turn_execution_core.gd")
const _RecentTurns = preload("res://src/llm_ai/llm_planning_recent_turns.gd")
const _RulesCatalog = preload("res://src/llm_ai/llm_planning_rules_catalog.gd")


static func _stable_unit_id(u: Unit) -> int:
	if u == null:
		return 0
	if u.has_meta("unit_id"):
		return int(u.get_meta("unit_id"))
	return u.get_instance_id()


static func _merge_enemies_for_threat(visible: Array, last_known: Array) -> Array:
	var merged: Array = []
	for e in visible:
		if e is Dictionary:
			merged.append(e)
	for e in last_known:
		if e is Dictionary:
			merged.append(e)
	return merged


## True if (tq,tr) lies on a straight hex ray from (eq,er) at hex distance in [min_d,max_d] along one axial direction.
static func _hex_ray_in_range(eq: int, er: int, tq: int, tr: int, min_d: int, max_d: int) -> bool:
	var dist: int = HexGrid.hex_distance(eq, er, tq, tr)
	if dist < min_d or dist > max_d:
		return false
	for d in HexGrid.AXIAL_DIRECTIONS:
		var nq: int = eq + d.x * dist
		var nr: int = er + d.y * dist
		if nq == tq and nr == tr:
			return true
	return false


## Max damage one enemy at (eq,er) could deal to (tq,tr) with one damaging ability from ability_keys (action_definitions).
static func _max_damage_ability_to_cell(eq: int, er: int, tq: int, tr: int, ability_keys: Array) -> int:
	var best: int = 0
	for ak in ability_keys:
		var key: String = str(ak)
		var cfg: Dictionary = Actions.get_action_config(key)
		if cfg.is_empty():
			continue
		var atype: String = str(cfg.get("type", ""))
		if atype not in ["fast ability", "ability", "slow ability"]:
			continue
		if not cfg.has("damage"):
			continue
		var dmg: int = int(cfg.get("damage", 0))
		if dmg <= 0:
			continue
		var pattern: String = str(cfg.get("pattern", ""))
		var min_r: int = int(cfg.get("min_range", 1))
		var max_r: int = int(cfg.get("max_range", 1))
		var can_hit: bool = false
		if pattern == "area_adjacent":
			can_hit = HexGrid.hex_distance(eq, er, tq, tr) == 1
		elif pattern == "self":
			can_hit = (eq == tq and er == tr)
		elif pattern == "ray":
			can_hit = _hex_ray_in_range(eq, er, tq, tr, min_r, max_r)
		else:
			var dist: int = HexGrid.hex_distance(eq, er, tq, tr)
			can_hit = dist >= min_r and dist <= max_r
		if can_hit:
			best = maxi(best, dmg)
	return best


## Aggregate threat to this option's end cell from all enemies (visible + last-known). Each unit may move OR attack per turn, so same-turn max damage to this cell assumes enemies hold and shoot from listed positions.
static func _threat_to_end_cell(ex: int, ey: int, all_enemies: Array) -> Dictionary:
	var incoming_hold: int = 0
	var enemy_count_can_hit: int = 0
	for enemy_entry in all_enemies:
		if not (enemy_entry is Dictionary):
			continue
		var ed: Dictionary = enemy_entry
		var c: Array = ed.get("cell", []) as Array
		var eq: int = int(c[0]) if c.size() >= 1 else 0
		var er: int = int(c[1]) if c.size() >= 2 else 0
		var keys: Array = ed.get("ability_action_keys", []) as Array
		if keys.is_empty():
			continue
		var d_hold: int = _max_damage_ability_to_cell(eq, er, ex, ey, keys)
		incoming_hold += d_hold
		if d_hold > 0:
			enemy_count_can_hit += 1
	return {
		"incoming_damage_if_enemies_hold_and_shoot_end": incoming_hold,
		"enemy_count_can_hit_end_if_hold": enemy_count_can_hit,
		"is_end_cell_threatened_if_hold": incoming_hold > 0,
	}


## End cells reachable by one move action from (eq,er) using action config min/max range (rings).
static func _end_cells_for_move_from(eq: int, er: int, cfg: Dictionary) -> Array:
	var min_r: int = int(cfg.get("min_range", 1))
	var max_r: int = int(cfg.get("max_range", 1))
	var out_cells: Array = []
	for dist in range(min_r, max_r + 1):
		var ring: Array = HexGrid.get_hexes_at_distance(eq, er, dist)
		for h in ring:
			out_cells.append([int(h.x), int(h.y)])
		if out_cells.size() > 48:
			break
	return out_cells


## Top-k style plausible one-turn actions for opponent prediction (option 3): hold+attack vs move-only vs utility.
static func _build_enemy_reaction_candidates(enemy_entry: Dictionary) -> Dictionary:
	var unit_id: int = int(enemy_entry.get("unit_id", 0))
	var c: Array = enemy_entry.get("cell", []) as Array
	var eq: int = int(c[0]) if c.size() >= 1 else 0
	var er: int = int(c[1]) if c.size() >= 2 else 0
	var uname: String = str(enemy_entry.get("name", "unit"))
	var def_path: String = str(enemy_entry.get("def", ""))
	var ability_keys: Array = enemy_entry.get("ability_action_keys", []) as Array

	var move_keys: Array = []
	var passive_keys: Array = []
	if not def_path.is_empty():
		var res = load(def_path)
		if res is UnitDefinition:
			move_keys = res.get_move_action_keys_resolved()
			for pk in res.passive_action_keys:
				passive_keys.append(str(pk))

	var candidates: Array = []
	var seen_attack_keys: Dictionary = {}

	for ak in ability_keys:
		var key: String = str(ak)
		var cfg: Dictionary = Actions.get_action_config(key)
		if cfg.is_empty():
			continue
		var atype: String = str(cfg.get("type", ""))
		if atype not in ["fast ability", "ability", "slow ability"]:
			continue
		if cfg.has("damage") and int(cfg.get("damage", 0)) > 0:
			seen_attack_keys[key] = true
			candidates.append({
				"type": "attack_from_current_cell",
				"action_key": key,
				"min_range": int(cfg.get("min_range", 1)),
				"max_range": int(cfg.get("max_range", 1)),
				"pattern": str(cfg.get("pattern", "")),
				"damage": int(cfg.get("damage", 0)),
				"summary": "Stay on from_cell; use %s — target hex must satisfy min/max range and pattern in action_definitions." % key,
			})

	for mk in move_keys:
		var key: String = str(mk)
		var cfg: Dictionary = Actions.get_action_config(key)
		if cfg.is_empty():
			continue
		var mtype: String = str(cfg.get("type", ""))
		if mtype not in ["move", "fast move", "slow move"]:
			continue
		var ends: Array = _end_cells_for_move_from(eq, er, cfg)
		candidates.append({
			"type": "move_only_no_same_turn_attack",
			"action_key": key,
			"possible_end_cells": ends,
			"summary": "Move with %s; cannot also use a damaging attack this turn (one action per unit)." % key,
		})

	for ak in ability_keys:
		var key: String = str(ak)
		if seen_attack_keys.has(key):
			continue
		var cfg: Dictionary = Actions.get_action_config(key)
		if cfg.is_empty():
			continue
		var atype: String = str(cfg.get("type", ""))
		if atype not in ["fast ability", "ability", "slow ability"]:
			continue
		candidates.append({
			"type": "non_damage_ability",
			"action_key": key,
			"summary": "Spend the turn on %s (utility / no direct damage from this action key)." % key,
		})

	var out: Dictionary = {
		"unit_id": unit_id,
		"name": uname,
		"from_cell": [eq, er],
		"one_action_per_turn": "Each enemy unit chooses exactly one action: move OR one ability — never both.",
		"candidates": candidates,
	}
	if not passive_keys.is_empty():
		out["passive_action_keys"] = passive_keys
		out["passive_note"] = "Passives may still resolve by rules; they do not replace the single chosen action unless rules_digest says otherwise."
	return out


static func _build_all_enemy_reaction_candidates(merged_enemies: Array) -> Array:
	var out: Array = []
	for e in merged_enemies:
		if e is Dictionary:
			out.append(_build_enemy_reaction_candidates(e))
	return out


static func _cell_key_from_array(cell_arr: Array) -> String:
	if cell_arr.size() < 2:
		return ""
	return "%d,%d" % [int(cell_arr[0]), int(cell_arr[1])]


static func _covered_cells_for_action(attacker_cell: Vector2, ac: ActionInstance, config: Dictionary) -> Array:
	var out: Array = []
	if ac == null or ac.definition == null:
		return out
	var base_cells: Array = TurnExecutionCore.get_damage_cells_for_config(
		int(attacker_cell.x), int(attacker_cell.y), ac.path, ac.end_point, config
	)
	var seen: Dictionary = {}
	for c in base_cells:
		var v: Vector2i = c as Vector2i
		var arr: Array = [int(v.x), int(v.y)]
		var key: String = _cell_key_from_array(arr)
		if key.is_empty() or seen.has(key):
			continue
		seen[key] = true
		out.append(arr)
	var aoe: Dictionary = config.get("area_of_effect", {}) as Dictionary
	if not aoe.is_empty():
		var aoe_cells: Array = HexGrid.get_aoe_tiles(attacker_cell, ac.end_point, aoe)
		for c in aoe_cells:
			var v2: Vector2 = c as Vector2
			var arr2: Array = [int(v2.x), int(v2.y)]
			var key2: String = _cell_key_from_array(arr2)
			if key2.is_empty() or seen.has(key2):
				continue
			seen[key2] = true
			out.append(arr2)
	return out


static func _covered_enemy_info_for_cells(covered_cells: Array, visible_enemies: Array) -> Dictionary:
	var covered_enemy_ids: Array = []
	var enemy_id_to_cell: Dictionary = {}
	for e in visible_enemies:
		if not (e is Dictionary):
			continue
		var ed: Dictionary = e
		var eid: int = int(ed.get("unit_id", 0))
		if eid == 0:
			continue
		var cell_arr: Array = ed.get("cell", []) as Array
		if cell_arr.size() < 2:
			continue
		enemy_id_to_cell[eid] = cell_arr
	for c in covered_cells:
		if not (c is Array):
			continue
		var key: String = _cell_key_from_array(c as Array)
		if key.is_empty():
			continue
		for eid in enemy_id_to_cell.keys():
			var ec: Array = enemy_id_to_cell[eid] as Array
			if _cell_key_from_array(ec) == key:
				covered_enemy_ids.append(int(eid))
	var unique_ids: Array = []
	var seen_ids: Dictionary = {}
	for eid in covered_enemy_ids:
		if seen_ids.has(eid):
			continue
		seen_ids[eid] = true
		unique_ids.append(eid)
	return {
		"covered_enemy_unit_ids": unique_ids,
		"expected_visible_hits_if_targeted": unique_ids.size(),
	}


const _HOLD_THREAT_KEYS: Array[String] = [
	"incoming_damage_if_enemies_hold_and_shoot_end",
	"enemy_count_can_hit_end_if_hold",
	"is_end_cell_threatened_if_hold",
]


## Engine `legal_options` for a unit (same indices as PlanningAI), without AI-only threat/distance fields.
static func _build_slim_legal_options_for_unit(u: Unit, board_hex_radius: int) -> Array:
	var opts: Array = PlanningAI._collect_all_options(u)
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
			"action_key": str(ac.definition.action_key),
			"path": path_arr,
			"end": [ex, ey],
			"end_cell": [ex, ey],
			"is_move": is_move,
			"dist_from_origin": dist0,
		}
		if board_hex_radius > 0:
			opt_dict["dist_from_map_edge"] = board_hex_radius - dist0
		var ak_slim: String = str(ac.definition.action_key)
		opt_dict["action_resolution_phase_index"] = Actions.resolution_phase_index_for_action_key(ak_slim)
		opt_dict["action_resolution_phase_name"] = Actions.resolution_phase_name_for_action_key(ak_slim)
		legal.append(opt_dict)
	return legal


## Two-call prediction pass: smaller payload — no hold-based threat per AI option, no enemy_reaction_candidates blob.
## Keeps enemy_units_legal_options so the model sees each enemy's full engine option list.
static func prepare_snapshot_for_prediction_api_call(snapshot: Dictionary) -> void:
	snapshot.erase("enemy_reaction_candidates")
	for u in snapshot.get("ai_units", []) as Array:
		if not (u is Dictionary):
			continue
		for opt in (u as Dictionary).get("legal_options", []) as Array:
			if not (opt is Dictionary):
				continue
			var od: Dictionary = opt
			for k in _HOLD_THREAT_KEYS:
				od.erase(k)


## Merge visible + last-known enemy entries by unit_id (visible wins).
static func _enemy_entries_by_id(snapshot: Dictionary) -> Dictionary:
	var by_id: Dictionary = {}
	for e in snapshot.get("visible_enemy_units", []) as Array:
		if e is Dictionary:
			by_id[int((e as Dictionary).get("unit_id", 0))] = e
	for e in snapshot.get("last_known_enemy_positions", []) as Array:
		if not (e is Dictionary):
			continue
		var ed: Dictionary = e
		var uid: int = int(ed.get("unit_id", 0))
		if uid != 0 and not by_id.has(uid):
			by_id[uid] = ed
	return by_id


## Damage to (ex,ey) if enemy executes top1 and it geometrically matches action_definitions.
static func _predicted_damage_from_top1(enemy_entry: Dictionary, top1: Dictionary, ex: int, ey: int) -> int:
	if not (top1 is Dictionary):
		return 0
	var t1: Dictionary = top1
	var action_key: String = str(t1.get("action_key", "")).strip_edges()
	if action_key.is_empty():
		return 0
	var cfg: Dictionary = Actions.get_action_config(action_key)
	if cfg.is_empty():
		return 0
	var mtype: String = str(cfg.get("type", ""))
	if mtype in ["move", "fast move", "slow move"]:
		return 0
	if not cfg.has("damage") or int(cfg.get("damage", 0)) <= 0:
		return 0
	var end_arr: Array = t1.get("end", []) as Array
	var tq: int = int(end_arr[0]) if end_arr.size() >= 1 else -999999
	var tr: int = int(end_arr[1]) if end_arr.size() >= 2 else -999999
	if ex != tq or ey != tr:
		return 0
	var c: Array = enemy_entry.get("cell", []) as Array
	var eq: int = int(c[0]) if c.size() >= 1 else 0
	var er: int = int(c[1]) if c.size() >= 2 else 0
	var geo: int = _max_damage_ability_to_cell(eq, er, ex, ey, [action_key])
	if geo <= 0:
		return 0
	return int(cfg.get("damage", 0))


## Minimum ACTION_ORDER phase index among predicted enemy top1 actions that deal damage (attacks/abilities).
static func _min_predicted_enemy_damage_action_phase(preds: Array) -> int:
	var best: int = 999
	for pe in preds:
		if not (pe is Dictionary):
			continue
		var t1: Variant = (pe as Dictionary).get("top1", {})
		if not (t1 is Dictionary):
			continue
		var t1d: Dictionary = t1
		if t1d.is_empty():
			continue
		var ak: String = str(t1d.get("action_key", "")).strip_edges()
		if ak.is_empty():
			continue
		var cfg: Dictionary = Actions.get_action_config(ak)
		var mtype: String = str(cfg.get("type", ""))
		if mtype in ["move", "fast move", "slow move"]:
			continue
		if not cfg.has("damage") or int(cfg.get("damage", 0)) <= 0:
			continue
		var idx: int = Actions.resolution_phase_index_for_action_key(ak)
		if idx >= 0:
			best = mini(best, idx)
	if best == 999:
		return -1
	return best


## Two-call action pass: replace hold-based threat with engine numbers derived from structured enemy_prediction_hypotheses.
static func apply_prediction_hypotheses_to_legal_options(snapshot: Dictionary, hypotheses: Dictionary) -> void:
	if hypotheses.is_empty():
		return
	var preds: Array = hypotheses.get("enemy_predictions", []) as Array
	if preds.is_empty():
		return
	var by_id: Dictionary = _enemy_entries_by_id(snapshot)
	var enemy_dmg_phase: int = _min_predicted_enemy_damage_action_phase(preds)
	for u in snapshot.get("ai_units", []) as Array:
		if not (u is Dictionary):
			continue
		for opt in (u as Dictionary).get("legal_options", []) as Array:
			if not (opt is Dictionary):
				continue
			var od: Dictionary = opt
			for k in _HOLD_THREAT_KEYS:
				od.erase(k)
			var end_a: Array = od.get("end", []) as Array
			var ex: int = int(end_a[0]) if end_a.size() >= 1 else 0
			var ey: int = int(end_a[1]) if end_a.size() >= 2 else 0
			var total: int = 0
			var n_hit: int = 0
			for pe in preds:
				if not (pe is Dictionary):
					continue
				var ped: Dictionary = pe
				var euid: int = int(ped.get("enemy_unit_id", 0))
				if euid == 0:
					continue
				var enemy_entry: Variant = by_id.get(euid, null)
				if enemy_entry == null or not (enemy_entry is Dictionary):
					continue
				var top1: Variant = ped.get("top1", {})
				var d: int = _predicted_damage_from_top1(enemy_entry, top1, ex, ey)
				if d > 0:
					total += d
					n_hit += 1
			od["pred_damage_at_end"] = total
			od["pred_enemies_hitting"] = n_hit
			od["pred_end_threatened"] = total > 0
			var our_ph: int = int(od.get("action_resolution_phase_index", -1))
			if our_ph < 0:
				var ak_opt2: String = str(od.get("action_key", ""))
				our_ph = Actions.resolution_phase_index_for_action_key(ak_opt2)
				od["action_resolution_phase_index"] = our_ph
				od["action_resolution_phase_name"] = Actions.resolution_phase_name_for_action_key(ak_opt2)
			od["predicted_enemy_damage_action_phase_index"] = enemy_dmg_phase
			if enemy_dmg_phase < 0:
				od["predicted_enemy_damage_timing_vs_our_action"] = "no_predicted_enemy_damage_action"
			elif our_ph < 0:
				od["predicted_enemy_damage_timing_vs_our_action"] = "unknown_our_phase"
			elif our_ph < enemy_dmg_phase:
				od["predicted_enemy_damage_timing_vs_our_action"] = "our_action_resolves_first"
			elif our_ph == enemy_dmg_phase:
				od["predicted_enemy_damage_timing_vs_our_action"] = "same_global_phase_as_predicted_enemy_damage"
			else:
				od["predicted_enemy_damage_timing_vs_our_action"] = "predicted_enemy_damage_resolves_first"
			if total > 0 and enemy_dmg_phase >= 0 and our_ph >= 0:
				if our_ph < enemy_dmg_phase:
					od["pred_damage_resolution_note"] = (
						"pred_damage_at_end applies if predicted attacks target this end hex: your action resolves in an earlier global phase than enemy damaging actions, "
						+ "so you occupy this cell when their attacks resolve."
					)
				elif our_ph == enemy_dmg_phase:
					od["pred_damage_resolution_note"] = (
						"pred_damage_at_end if predicted attacks target this end hex: same global phase as enemy damage—order within the phase follows engine rules."
					)
				else:
					od["pred_damage_resolution_note"] = (
						"pred_damage_at_end may overstate damage: predicted enemy damaging actions resolve in an earlier global phase than your action."
					)
	snapshot.erase("enemy_reaction_candidates")
	snapshot.erase("enemy_units_legal_options")


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

	var scenario_dict: Dictionary = Scenarios.get_selected_scenario()
	var scenario_objective: String = str(scenario_dict.get("description", "")).strip_edges()
	var win_line := "Win by eliminating all enemy units (last side with any unit on the board wins)."
	if not scenario_objective.is_empty():
		win_line = "Scenario objective: %s Standard win rule: eliminate all opposing units." % scenario_objective
	var phase_bits: PackedStringArray = PackedStringArray()
	for ph in Actions.ACTION_ORDER:
		phase_bits.append(str(ph))
	var phase_order_txt := ", ".join(phase_bits)
	var rules_stub := (
		"Turn: planning then simultaneous execution. %s "
		% win_line
		+ "Each unit performs exactly ONE action per turn (move OR ability/attack — never both). A unit that attacked or used an ability did NOT also move; it remains at its pre-turn position. "
		+ "Execution phase order (all sides resolve each phase before the next): %s. "
		% phase_order_txt
		+ "Each action key's \"type\" in action_definitions is its phase (e.g. fast move vs move vs ability). "
		+ "Fast move and fast ability resolve before move, normal ability, slow move, and slow ability—use fast move to guarantee reaching a hex or an enemy before units that only have normal/slow timing can relocate or strike. "
		+ "There is no friendly fire: damaging attacks and AoE never reduce allied units' HP (same side only); heals and ally-targeted supports never damage enemies. "
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
		var enemy_ability_keys: Array = []
		if u.def:
			for ak in u.def.ability_action_keys:
				enemy_ability_keys.append(str(ak))
		var enemy_entry: Dictionary = {
			"unit_id": _stable_unit_id(u),
			"cell": [int(u.cell.x), int(u.cell.y)],
			"health": u.health,
			"max_health": u.max_health,
			"group": gname,
			"def": u.def.resource_path if u.def else "",
			"name": u.def.name if u.def else "unit",
		}
		if not enemy_ability_keys.is_empty():
			enemy_entry["ability_action_keys"] = enemy_ability_keys
		enemies_visible.append(enemy_entry)

	# Update last-known enemy positions and gather non-visible intel.
	var observer_group: String = units.ai_group_names[0] if units.ai_group_names.size() > 0 else ""
	if not observer_group.is_empty() and units.has_method("update_last_known_enemies_for_group"):
		units.update_last_known_enemies_for_group(observer_group, enemies_visible)
	var visible_uid_set: Dictionary = {}
	for ev in enemies_visible:
		visible_uid_set[int(ev.get("unit_id", 0))] = true
	var last_known_enemies: Array = []
	if not observer_group.is_empty() and units.has_method("get_nonvisible_known_enemies"):
		last_known_enemies = units.get_nonvisible_known_enemies(observer_group, visible_uid_set)

	var merged_enemies_for_threat: Array = _merge_enemies_for_threat(enemies_visible, last_known_enemies)

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
				"action_key": str(ac.definition.action_key),
				"path": path_arr,
				"end": [ex, ey],
				"end_cell": [ex, ey],
				"is_move": is_move,
				## Hex distance of this option's end cell from map origin (0,0); matches map_bounds.hex_radius on the outer ring.
				"dist_from_origin": dist0,
			}
			if board_hex_radius > 0:
				opt_dict["dist_from_map_edge"] = board_hex_radius - dist0
			## Same order as visible_enemy_units; hex distance from this option's end cell to each visible enemy.
			var dists_enemies: Array = []
			var visible_enemy_ids_at_end: Array = []
			for enemy_entry in enemies_visible:
				if typeof(enemy_entry) != TYPE_DICTIONARY:
					continue
				var ed: Dictionary = enemy_entry
				var ec: Array = ed.get("cell", []) as Array
				var eq: int = int(ec[0]) if ec.size() >= 1 else 0
				var er: int = int(ec[1]) if ec.size() >= 2 else 0
				var eid: int = int(ed.get("unit_id", 0))
				dists_enemies.append({
					"unit_id": eid,
					"hex_dist": HexGrid.hex_distance(ex, ey, eq, er),
				})
				if eq == ex and er == ey and eid != 0:
					visible_enemy_ids_at_end.append(eid)
			opt_dict["distances_to_visible_enemies"] = dists_enemies
			opt_dict["visible_enemy_ids_at_end"] = visible_enemy_ids_at_end
			opt_dict["end_has_visible_enemy"] = not visible_enemy_ids_at_end.is_empty()
			opt_dict["expected_visible_hits_if_targeted"] = visible_enemy_ids_at_end.size()
			var cfg: Dictionary = Actions.get_action_config(str(ac.definition.action_key))
			if not is_move and int(cfg.get("damage", 0)) > 0:
				var covered_cells: Array = _covered_cells_for_action(u.cell, ac, cfg)
				opt_dict["target_cell"] = [ex, ey]
				opt_dict["covered_cells"] = covered_cells
				var hit_info: Dictionary = _covered_enemy_info_for_cells(covered_cells, enemies_visible)
				opt_dict["covered_enemy_unit_ids"] = hit_info.get("covered_enemy_unit_ids", []) as Array
				opt_dict["expected_visible_hits_if_targeted"] = int(
					hit_info.get("expected_visible_hits_if_targeted", 0)
				)
				opt_dict["expected_damage_now"] = int(cfg.get("damage", 0)) * int(
					hit_info.get("expected_visible_hits_if_targeted", 0)
				)
			if not last_known_enemies.is_empty():
				var dists_last_known: Array = []
				for lk_entry in last_known_enemies:
					var lk_cell: Array = lk_entry.get("cell", []) as Array
					var lkq: int = int(lk_cell[0]) if lk_cell.size() >= 1 else 0
					var lkr: int = int(lk_cell[1]) if lk_cell.size() >= 2 else 0
					dists_last_known.append({
						"unit_id": int(lk_entry.get("unit_id", 0)),
						"hex_dist": HexGrid.hex_distance(ex, ey, lkq, lkr),
					})
				opt_dict["distances_to_last_known_enemies"] = dists_last_known
			var threat_metrics: Dictionary = _threat_to_end_cell(ex, ey, merged_enemies_for_threat)
			opt_dict["incoming_damage_if_enemies_hold_and_shoot_end"] = threat_metrics.get(
				"incoming_damage_if_enemies_hold_and_shoot_end", 0
			)
			opt_dict["enemy_count_can_hit_end_if_hold"] = threat_metrics.get("enemy_count_can_hit_end_if_hold", 0)
			opt_dict["is_end_cell_threatened_if_hold"] = threat_metrics.get("is_end_cell_threatened_if_hold", false)
			var ak_opt: String = str(ac.definition.action_key)
			opt_dict["action_resolution_phase_index"] = Actions.resolution_phase_index_for_action_key(ak_opt)
			opt_dict["action_resolution_phase_name"] = Actions.resolution_phase_name_for_action_key(ak_opt)
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

	var enemy_units_legal_options: Array = []
	for u in units.get_active_units():
		if not (is_instance_valid(u) and u is Unit and u.is_active):
			continue
		var egname: String = u.get_parent().name if u.get_parent() else ""
		if egname in units.ai_group_names:
			continue
		var euid := _stable_unit_id(u)
		enemy_units_legal_options.append({
			"unit_id": euid,
			"cell": [int(u.cell.x), int(u.cell.y)],
			"health": u.health,
			"max_health": u.max_health,
			"name": u.def.name if u.def else "unit",
			"group": egname,
			"def": u.def.resource_path if u.def else "",
			"legal_options": _build_slim_legal_options_for_unit(u, board_hex_radius),
		})

	var enemy_intel: Dictionary = {
		"initial_count": int(units.get("_ai_initial_enemy_count") if units.get("_ai_initial_enemy_count") != null else 0),
		"confirmed_kills": int(units.get("_ai_confirmed_enemy_kills") if units.get("_ai_confirmed_enemy_kills") != null else 0),
		"currently_visible": enemies_visible.size(),
	}

	var phase_order: Array[String] = []
	for ph in Actions.ACTION_ORDER:
		phase_order.append(str(ph))

	var result: Dictionary = {
		"rules_digest": rules_stub,
		"rules_version": "v2_catalog",
		"action_resolution_phase_order": phase_order,
		"action_definitions": _RulesCatalog.build_action_definitions(),
		"unit_type_definitions": _RulesCatalog.build_unit_type_definitions(),
		"scenario_id": Scenarios.selected_scenario_id,
		"scenario_description": scenario_objective,
		"turn": units.turn_number,
		"enemy_intel": enemy_intel,
		"visible_enemy_units": enemies_visible,
		"ai_units": ai_units,
		"map_bounds": map_bounds,
		"recent_turns": _RecentTurns.build_for_llm(units),
	}
	if not last_known_enemies.is_empty():
		result["last_known_enemy_positions"] = last_known_enemies
	if not merged_enemies_for_threat.is_empty():
		result["enemy_reaction_candidates"] = _build_all_enemy_reaction_candidates(merged_enemies_for_threat)
	if not enemy_units_legal_options.is_empty():
		result["enemy_units_legal_options"] = enemy_units_legal_options
	return result
